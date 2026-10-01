using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// Collect-errors (XmlReadConfig.CollectErrors): after an error, NextEvent calls Recover to put the
/// reader where reading can go on, and returns the error; the next call reads from there. Recovery never
/// fails and never makes an error itself (the pending one's message lives in the per-thread buffer).
extension XmlReaderCore<TCursor>
{
	/// Whether the read can go on after the error in mError: not after an error of the input itself
	/// (encoding, I/O, before the input was set up), a resource limit, or MaxErrors errors.
	bool CanRecover()
	{
		if (mState == .Start || mState == .Failed || mInputFailed || mCursor.HasInputError)
			return false;
		switch (mError.mKind)
		{
		case .InvalidEncoding, .UnsupportedEncoding, .IoError, .ResourceLimitExceeded:
			return false;
		default:
		}
		return mConfig.MaxErrors <= 0 || mErrorCount + 1 < mConfig.MaxErrors;
	}

	/// Puts the reader after the broken construct: out of entities, past a broken tag, comment, PI,
	/// CDATA section, reference or DOCTYPE, or at the next `<`; a mismatched end tag closes the elements
	/// down to the one it names; at the end of the input, open elements are closed. Always progresses.
	void Recover()
	{
		mErrorCount++;
		int errorOffset = (int)mError.mOffset;
		let kind = mError.mKind;
		mPendingEnd = false;

		// A broken start tag in the document (an error in it may come from an entity in a value); one that
		// began in an entity's text goes with the entity
		bool tagInDocument = mTagStart >= 0 && mTagFrames == 0;
		// Out of every entity: reading goes on after the outermost reference
		bool wasInEntity = mFrames.Count > 0;
		if (wasInEntity)
		{
			let outer = mFrames[0];
			for (let frame in mFrames)
				frame.mEntity.mExpanding = false;
			mData = outer.mData;
			mBase = outer.mBase;
			mEnd = outer.mEnd;
			mPos = outer.mPos;
			mRetain = outer.mRetain;
			mFrames.Clear();
			for (int i < mElements.Count)
				mElements[i].mFrameLevel = 0;
		}

		// Where the broken construct is known to end, from where the error is (mPos may have moved on
		// inside the construct, by how much depending on the buffer). One error is found past it: an
		// undeclared entity in an attribute default, once the DOCTYPE has ended (mPos is after it).
		int from = Math.Max(errorOffset, mBase);
		if (kind == .UndeclaredEntity && mState == .Prolog && !mDocTypeOpen)
			from = Math.Max(from, mPos);
		int resume;
		if (tagInDocument && mState == .Content && errorOffset >= mTagStart)
			resume = SkipBrokenStartTag();
		else if (mState == .InternalSubset && !wasInEntity)
			resume = NextMarkup(from + 1, true);
		else if (mState != .InternalSubset && (mDocTypeOpen || (!wasInEntity && errorOffset >= mBase && StartsWith(errorOffset, "<!DOCTYPE"))))
		{
			// A broken DOCTYPE header, or one where none can be: skipped, subset and all
			resume = SkipDocType(from);
			mDocTypeOpen = false;
		}
		else if (wasInEntity)
			resume = mPos;
		else if (kind == .MismatchedEndTag && mState == .Content && StartsWith(mPos, "</"))
			resume = RecoverEndTag(mPos);
		else if (kind == .UnclosedElement)
		{
			mClosingAtEnd = true;
			resume = mPos;
		}
		else if (kind == .InvalidComment)
			resume = After(from, "-->");
		else if (kind == .InvalidProcessingInstruction || kind == .InvalidXmlDeclaration)
			resume = After(from, "?>");
		else if (kind == .InvalidCData)
			resume = After(from, "]]>");
		else if (mState == .Epilog && At(from) == '<' && XmlChar.NameByteClass(At(from + 1)) != XmlChar.cNameStop)
			resume = SkipElement(from);
		else if (At(from) == '&')
			resume = AfterReference(from);
		else
			resume = NextMarkup(from + 1, false);

		// Always forward: an error where the last one was moves on a byte
		if (errorOffset == mLastErrorOffset && resume <= errorOffset)
			resume = errorOffset + 1;
		mLastErrorOffset = errorOffset;
		mPos = Math.Max(resume, mPos);
		Release(mPos);
		mTagStart = -1;

		// The end of the input: close what is open, else end
		if (!Avail(mPos))
		{
			if (mState == .Content && mElements.Count > 0)
				mClosingAtEnd = true;
			else if (mState != .Content)
				mState = .End;
		}
		if (mState == .Content && mElements.Count == 0 && mCloseTo < 0)
			mState = .Prolog;
	}

	/// After a broken start tag: past its `>` (quotes stepped over; if a quote is never closed, the first
	/// `>` after the error), remembered as a phantom unless it was `/>`, so its end tag goes quietly.
	int SkipBrokenStartTag()
	{
		int end = FindTagEnd(mTagStart + 1);
		if (end < 0)
			end = Find(Math.Max(Math.Max((int)mError.mOffset, mTagStart + 1), mBase), ">");
		if (end < 0)
			return NextMarkup(mTagStart + 1, false);
		bool empty = end > mTagStart && mData[end - 1] == '/';
		if (!empty)
		{
			// Its name, if it got that far
			int nameEnd = mTagStart + 1;
			while (nameEnd < end && IsNameCharAt(nameEnd))
				nameEnd++;
			XmlNameId name = (nameEnd > mTagStart + 1) ? mNames.Find(View(mTagStart + 1, nameEnd - mTagStart - 1)) : .None;
			if (name.IsValid)
				mPhantoms.Add((name, mElements.Count));
		}
		return end + 1;
	}

	/// The `>` ending the tag whose content starts at `pos`, quoted values stepped over; -1 if a quote is
	/// not closed (or the input ends).
	int FindTagEnd(int pos)
	{
		int p = pos;
		char8 quote = 0;
		while (Avail(p))
		{
			char8 c = mData[p];
			if (quote != 0)
			{
				if (c == quote)
					quote = 0;
			}
			else if (c == '"' || c == '\'')
				quote = c;
			else if (c == '>')
				return p;
			else if (c == '<')
				return -1;
			p++;
		}
		return -1;
	}

	/// Lets a stream drop what is before `pos`, except, in the internal subset, the subset (the DocType
	/// event views it whole).
	void Release(int pos)
	{
		mRetain = (mState == .InternalSubset && mSubsetStart >= 0) ? mSubsetStart : pos;
	}

	/// A mismatched end tag at `pos`: when an open element has its name, the elements above it and it are
	/// closed (one EndElement per call); otherwise it is dropped. @return The position after it.
	int RecoverEndTag(int pos)
	{
		int nameEnd = pos + 2;
		while (IsNameCharAt(nameEnd))
			nameEnd++;
		XmlNameId name = mNames.Find(View(pos + 2, nameEnd - pos - 2));
		int close = Find(nameEnd, ">");
		int after = (close >= 0 && close <= NextMarkup(nameEnd, false)) ? close + 1 : nameEnd;
		if (name.IsValid)
		{
			for (int i = mElements.Count - 1; i >= 0; i--)
			{
				if (mElements[i].mName == name)
				{
					mCloseTo = i;
					mCloseStart = pos;
					mCloseEnd = after;
					// ReadNext closes them, through its pending-end check
					mPendingEnd = true;
					break;
				}
			}
		}
		return after;
	}

	/// Collect-errors: an end tag that names no open element but the latest start tag that failed at this
	/// depth: it is consumed with no event and no error. @return Whether it was one.
	bool DropPhantomEndTag(int start, StringView name)
	{
		// Phantoms from deeper levels than now are gone
		while (!mPhantoms.IsEmpty && mPhantoms.Back.depth > mElements.Count)
			mPhantoms.PopBack();
		if (mPhantoms.IsEmpty || mPhantoms.Back.depth != mElements.Count || mNames[mPhantoms.Back.name] != name)
			return false;
		int close = Find(start + 2 + name.Length, ">");
		if (close < 0)
			return false;
		mPhantoms.PopBack();
		mPos = close + 1;
		return true;
	}

	/// Past a DOCTYPE starting at `pos` (or the rest of one): its `>`, after the internal subset's `]`
	/// when it has one.
	int SkipDocType(int pos)
	{
		int bracket = Find(pos, "[");
		int close = Find(pos, ">");
		if (bracket >= 0 && (close < 0 || bracket < close))
		{
			int subsetEnd = Find(bracket, "]");
			close = subsetEnd >= 0 ? Find(subsetEnd, ">") : -1;
		}
		return close >= 0 ? close + 1 : EndOfInput(pos);
	}

	/// Past a whole element starting at `pos` (a second root): its start tag and, unless it is empty,
	/// everything to its matching end tag (tags counted, comments, PIs and CDATA sections stepped over).
	int SkipElement(int pos)
	{
		int depth = 0;
		int p = pos;
		while (Avail(p))
		{
			Release(p);
			if (mData[p] != '<')
			{
				p++;
				continue;
			}
			if (StartsWith(p, "<!--"))
				p = After(p + 4, "-->");
			else if (StartsWith(p, "<![CDATA["))
				p = After(p + 9, "]]>");
			else if (StartsWith(p, "<?"))
				p = After(p + 2, "?>");
			else if (StartsWith(p, "</"))
			{
				p = After(p + 2, ">");
				if (--depth <= 0)
					return p;
			}
			else
			{
				int end = FindTagEnd(p + 1);
				if (end < 0)
					return NextMarkup(p + 1, false);
				p = end + 1;
				if (mData[end - 1] != '/')
					depth++;
				else if (depth == 0)
					return p;
			}
		}
		return p;
	}

	/// Past a broken reference at `pos`: its `;` when one comes before the next markup.
	int AfterReference(int pos)
	{
		int semicolon = Find(pos, ";");
		int markup = NextMarkup(pos + 1, false);
		return (semicolon >= 0 && semicolon < markup) ? semicolon + 1 : markup;
	}

	/// The position just after `literal`, searched from `pos`, or the end of the input.
	int After(int pos, StringView literal)
	{
		int found = Find(pos, literal);
		return found >= 0 ? found + literal.Length : EndOfInput(pos);
	}

	/// The next `<` from `pos` (in the internal subset, also `]`), or the end of the input.
	int NextMarkup(int pos, bool subset)
	{
		int p = pos;
		while (Avail(p))
		{
			char8 c = mData[p];
			if (c == '<' || (subset && c == ']'))
				return p;
			p++;
			Release(p);
		}
		return p;
	}

	/// Where `literal` starts at or after `pos`, or -1.
	int Find(int pos, StringView literal)
	{
		int p = pos;
		while (Avail(p))
		{
			if (mData[p] == literal[0] && StartsWith(p, literal))
				return p;
			p++;
		}
		return -1;
	}

	int EndOfInput(int pos)
	{
		int p = pos;
		while (Avail(p))
		{
			p++;
			Release(p);
		}
		return p;
	}
}
