using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// The error type of the reader's internal methods: empty, so their results are no bigger than their
/// values (KdlBeef measured a large error in every Result as a real cost). The error itself is recorded
/// in the reader by Fail, and Next returns it.
internal struct XmlFailure
{
}

/// The reader itself, over a cursor (in-memory text; a buffered stream in phase 4). It reads through a
/// window: `mData[offset]` for `mBase <= offset < mEnd`, offsets absolute. Anything that may read at
/// the window's end asks for more first (`Avail`, `At`, `AvailN`); for in-memory text the window is the
/// whole input and those checks compile away.
///
/// Entity replacement text is read by the same code through input frames (`mFrames`): a reference
/// pushes the current window and reads the replacement text as the window until its end, where the
/// frame pops (§4.4.2 "included"; in attribute values "included in literal"; in the internal subset a
/// parameter entity between declarations). Constructs cannot cross a frame's end: the window simply
/// ends there. Elements must close in the frame they open in.
///
/// Invariants:
/// - **Event balance.** Every reported StartElement gets exactly one EndElement (an empty element's
///   comes on the next call).
/// - **Views.** Event strings view the window, an entity's replacement text, the name table or a
///   reader buffer: valid until the next event.
/// - **Errors are sticky.** The first error puts the reader in a failed state; Next returns it again.
internal class XmlReaderCore<TCursor> where TCursor : IXmlCursor
{
	enum State : uint8
	{
		/// Not validated yet.
		Start,
		/// Before the root element: the XML declaration, DOCTYPE, comments, PIs, whitespace.
		Prolog,
		/// Inside the DOCTYPE's internal subset: declarations, comments, parameter-entity references,
		/// and processing instructions (reported).
		InternalSubset,
		/// Inside the root element.
		Content,
		/// After the root element: comments, PIs, whitespace.
		Epilog,
		End,
		Failed
	}

	/// An open element.
	struct Element
	{
		public XmlNameId mName;
		public XmlNameId mNamespace;
		/// mFrames.Count when it opened: it must close in the same entity.
		public int32 mFrameLevel;
		/// mBindings.Count before its namespace declarations.
		public int32 mBindings;
		/// Document offset of its `<`.
		public int32 mStart;
	}

	/// A saved window under an entity's replacement text.
	struct InputFrame
	{
		public char8* mData;
		public int mBase;
		/// Where reading resumes when the frame pops (just after the reference).
		public int mPos;
		public int mEnd;
		public XmlEntity mEntity;
		/// mElements.Count when the frame was pushed.
		public int32 mElements;
		/// Document offset and length of the outermost reference (where errors inside are reported).
		public int32 mRefOffset;
		public int32 mRefLength;
	}

	/// An in-scope namespace declaration.
	struct Binding
	{
		public XmlNameId mPrefix;
		public XmlNameId mUri;
	}

	/// An attribute of the current start tag.
	internal struct AttributeRecord
	{
		public XmlNameId mName;
		public XmlNameId mPrefix;
		public XmlNameId mLocal;
		public XmlNameId mNamespace;
		public StringView mValue;
		/// The value's start in mAttributeBuffer, or -1 when mValue views the input.
		public int32 mBufferStart;
		public int32 mBufferLength;
		/// Document offset of the attribute's name.
		public int32 mOffset;
		/// Given in the tag (false: defaulted from an ATTLIST declaration).
		public bool mSpecified;
	}

	internal TCursor mCursor;
	char8* mData;
	int mBase;
	int mPos;
	int mEnd;
	/// The start of the construct being read: the cursor keeps bytes from here on in the window.
	int mRetain;
	/// The cursor stopped on an error of the input; the reader's next error is replaced by it.
	bool mInputFailed;
	State mState;
	/// Offset of the first content byte (after a BOM): only there can an XML declaration start.
	int mContentStart;
	bool mSeenDocType;
	/// The DOCTYPE being read: where it and its internal subset start.
	int mDocTypeStart;
	int mSubsetStart;
	XmlParseError mError;
	internal XmlReadConfig mConfig;

	List<Element> mElements ~ delete _;
	List<InputFrame> mFrames ~ delete _;
	List<Binding> mBindings ~ delete _;
	/// After an EndElement, its namespace declarations go out of scope on the next call (-1: none).
	int mBindingsToPop = -1;
	/// An empty element's EndElement is due.
	bool mPendingEnd;

	internal XmlNameTable mNames ~ delete _;
	internal XmlDtd mDtd ~ delete _;
	String mTextBuffer ~ delete _;
	String mAttributeBuffer ~ delete _;
	String mScratch ~ delete _;
	HashSet<XmlNameId> mSeenNames ~ delete _;
	/// The DOCTYPE's name and identifiers (kept while its internal subset is read).
	String mDocTypeName ~ delete _;
	String mDocTypePublicId ~ delete _;
	String mDocTypeSystemId ~ delete _;

	// The event
	internal XmlNameId mNameId;
	internal StringView mName;
	internal XmlNameId mNamespace;
	internal StringView mValue;
	internal bool mIsEmpty;
	internal int mDepth;
	internal int mEventOffset;
	internal int mEventEnd;
	internal List<AttributeRecord> mAttributes ~ delete _;
	internal StringView mVersion;
	internal StringView mEncodingName;
	internal XmlStandalone mStandalone;
	internal StringView mPublicId;
	internal StringView mSystemId;
	internal bool mHasPublicId;
	internal bool mHasSystemId;
	internal StringView mInternalSubset;

	// Interned names the namespace rules need
	internal XmlNameId mXmlPrefix;
	internal XmlNameId mXmlnsPrefix;
	internal XmlNameId mXmlUri;
	internal XmlNameId mXmlnsUri;

	/// Bytes produced by entity expansion so far.
	int mExpandedBytes;
	int mElementCount;

	internal const StringView cXmlNamespace = "http://www.w3.org/XML/1998/namespace";
	internal const StringView cXmlnsNamespace = "http://www.w3.org/2000/xmlns/";

	public this()
	{
		mElements = new .();
		mFrames = new .();
		mBindings = new .();
		mNames = new .();
		mDtd = new .();
		mTextBuffer = new .();
		mAttributeBuffer = new .();
		mScratch = new .();
		mSeenNames = new .();
		mDocTypeName = new .();
		mDocTypePublicId = new .();
		mDocTypeSystemId = new .();
		mAttributes = new .();
		mConfig = .();
	}

	public void Reset(TCursor cursor, XmlReadConfig config)
	{
		mCursor = cursor;
		mConfig = config;
		mData = null;
		mBase = 0;
		mPos = 0;
		mEnd = 0;
		mRetain = int.MaxValue;
		mInputFailed = false;
		mState = .Start;
		mContentStart = 0;
		mSeenDocType = false;
		mDocTypeStart = 0;
		mSubsetStart = 0;
		for (let frame in mFrames)
			frame.mEntity.mExpanding = false;
		mElements.Clear();
		mFrames.Clear();
		mBindings.Clear();
		mBindingsToPop = -1;
		mPendingEnd = false;
		mNames.Clear();
		mDtd.Clear();
		mAttributes.Clear();
		mNameId = .None;
		mName = default;
		mNamespace = .None;
		mValue = default;
		mIsEmpty = false;
		mDepth = 0;
		mEventOffset = 0;
		mEventEnd = 0;
		mVersion = default;
		mEncodingName = default;
		mStandalone = .Unspecified;
		mPublicId = default;
		mSystemId = default;
		mHasPublicId = false;
		mHasSystemId = false;
		mInternalSubset = default;
		mExpandedBytes = 0;
		mElementCount = 0;
		mXmlPrefix = mNames.Intern("xml");
		mXmlnsPrefix = mNames.Intern("xmlns");
		mXmlUri = mNames.Intern(cXmlNamespace);
		mXmlnsUri = mNames.Intern(cXmlnsNamespace);
	}

	/// The next event; on failure the error is in mError. (XmlReader.Next makes the public Result, so
	/// the large error is copied once.)
	[Inline]
	public Result<XmlEvent, XmlFailure> NextEvent()
	{
		if (mState == .Failed)
			return .Err(.());
		let result = ReadNext();
		if (result case .Err)
			mState = .Failed;
		return result;
	}

	/// Whether the read has stopped at an error.
	public bool IsStopped => mState == .Failed;

	internal XmlParseError Error => mError;

	/// A step's result when it read something that reports no event (never returned by Next).
	const XmlEvent cNoEvent = (XmlEvent)0xFF;

	Result<XmlEvent, XmlFailure> ReadNext()
	{
		if (mState == .Start)
			Try!(BeginInput());
		if (mBindingsToPop >= 0)
		{
			mBindings.Count = mBindingsToPop;
			mBindingsToPop = -1;
		}
		if (mPendingEnd)
		{
			mPendingEnd = false;
			return EndElement(mEventOffset, mEventEnd);
		}
		while (true)
		{
			XmlEvent event;
			switch (mState)
			{
			case .Prolog, .Epilog:
				event = Try!(StepMisc());
			case .Content:
				event = Try!(StepContent());
			case .InternalSubset:
				event = Try!(StepInternalSubset());
			case .End:
				return .Ok(.EndOfDocument);
			case .Start, .Failed:
				Runtime.FatalError("XmlReader: unreachable state");
			}
			if (event != cNoEvent)
				return .Ok(event);
		}
	}

	/// Detects the encoding, validates the input (a stream's first buffer) and sets up the window.
	Result<void, XmlFailure> BeginInput()
	{
		switch (mCursor.Begin(ref mData, ref mBase, ref mEnd))
		{
		case .Ok(let start):
			mPos = start;
			mContentStart = start;
		case .Err(let error):
			mError = error;
			if (!mConfig.SourceName.IsEmpty)
				mError.SetSource(mConfig.SourceName);
			return .Err(.());
		}
		mState = .Prolog;
		return .Ok;
	}

	/// Sets the event's depth and range (document offsets: inside an entity, its outermost reference).
	[Inline]
	void Report(int start, int end, int depth)
	{
		mDepth = depth;
		if (mFrames.Count == 0)
		{
			mEventOffset = start;
			mEventEnd = end;
		}
		else
		{
			mEventOffset = mFrames[0].mRefOffset;
			mEventEnd = mFrames[0].mRefOffset + mFrames[0].mRefLength;
		}
	}

	/// The document offset of `offset` in the current window (inside an entity, its outermost reference).
	[Inline]
	int DocOffset(int offset)
	{
		return mFrames.Count == 0 ? offset : mFrames[0].mRefOffset;
	}

	/// The document offset of the end of a construct ending at `offset` (inside an entity, the end of
	/// its outermost reference).
	[Inline]
	int DocEnd(int offset)
	{
		return mFrames.Count == 0 ? offset : mFrames[0].mRefOffset + mFrames[0].mRefLength;
	}

	// Before and after the root element

	Result<XmlEvent, XmlFailure> StepMisc()
	{
		mRetain = int.MaxValue;
		int p = SkipSpace(mPos);
		mPos = p;
		if (!Avail(p))
		{
			if (mInputFailed)
				return .Err(Fail(.IoError, "", p));
			if (mState == .Prolog)
				return .Err(Fail(.InvalidDocumentStructure, "The document has no root element", p, 0));
			mState = .End;
			Report(p, p, 0);
			return XmlEvent.EndOfDocument;
		}
		char8 c = mData[p];
		if (c != '<')
		{
			if (c == '&')
				return .Err(Fail(.InvalidDocumentStructure, mState == .Prolog ? "A reference cannot come before the root element" : "A reference cannot come after the root element", p));
			return .Err(Fail(.InvalidDocumentStructure, mState == .Prolog ? "Text cannot come before the root element" : "Text cannot come after the root element (only comments, processing instructions and whitespace can)", p));
		}
		mRetain = p;
		char8 next = At(p + 1);
		if (next == '?')
		{
			if (mState == .Prolog && p == mContentStart && IsXmlDeclarationStart(p))
				return ReadXmlDeclaration();
			return ReadProcessingInstruction(0);
		}
		if (next == '!')
		{
			if (StartsWith(p, "<!--"))
				return ReadComment(0);
			if (StartsWith(p, "<!DOCTYPE"))
			{
				if (mState == .Epilog)
					return .Err(Fail(.InvalidDocumentStructure, "A DOCTYPE cannot come after the root element", p, 9));
				if (mSeenDocType)
					return .Err(Fail(.InvalidDocumentStructure, "A document can have only one DOCTYPE", p, 9));
				return ReadDocType();
			}
			if (StartsWith(p, "<![CDATA["))
				return .Err(Fail(.InvalidDocumentStructure, mState == .Prolog ? "A CDATA section cannot come before the root element" : "A CDATA section cannot come after the root element", p, 9));
			return .Err(Fail(.UnexpectedChar, "Expected a comment (`<!--`) or a DOCTYPE (`<!DOCTYPE`) after `<!`", p, 2));
		}
		if (mState == .Epilog)
		{
			if (next == '/')
				return .Err(Fail(.MismatchedEndTag, "An end tag after the root element, which is already closed", p, 2));
			return .Err(Fail(.InvalidDocumentStructure, "A document can have only one root element", p));
		}
		if (next == '/')
			return .Err(Fail(.MismatchedEndTag, "An end tag before the root element", p, 2));
		mState = .Content;
		return ReadStartTag();
	}

	// Inside the root element

	Result<XmlEvent, XmlFailure> StepContent()
	{
		int p = mPos;
		mRetain = p;
		if (!Avail(p))
		{
			if (mFrames.Count > 0)
			{
				Try!(PopFrame());
				return cNoEvent;
			}
			if (mInputFailed)
				return .Err(Fail(.IoError, "", p));
			let open = mElements.Back;
			return .Err(Fail(.UnclosedElement, scope $"The element `{mNames[open.mName]}` is not closed", open.mStart, 1 + mNames[open.mName].Length));
		}
		if (mData[p] != '<')
			return ReadText();
		switch (At(p + 1))
		{
		case '/':
			return ReadEndTag();
		case '?':
			return ReadProcessingInstruction(mElements.Count);
		case '!':
			if (StartsWith(p, "<!--"))
				return ReadComment(mElements.Count);
			if (StartsWith(p, "<![CDATA["))
				return ReadCData();
			if (StartsWith(p, "<!DOCTYPE"))
				return .Err(Fail(.InvalidDocumentStructure, "A DOCTYPE cannot come inside the root element", p, 9));
			return .Err(Fail(.UnexpectedChar, "Expected a comment (`<!--`) or a CDATA section (`<![CDATA[`) after `<!`", p, 2));
		default:
			return ReadStartTag();
		}
	}

	/// Reports the EndElement of the innermost element (at the given range) and closes it.
	XmlEvent EndElement(int start, int end)
	{
		Element element = mElements.PopBack();
		mNameId = element.mName;
		mName = mNames[element.mName];
		mNamespace = element.mNamespace;
		mIsEmpty = false;
		mAttributes.Clear();
		mDepth = mElements.Count;
		mEventOffset = start;
		mEventEnd = end;
		// Its declarations stay in scope for this event (NamespaceUri, Prefix) and go on the next call
		mBindingsToPop = element.mBindings;
		if (mElements.Count == 0)
			mState = .Epilog;
		return .EndElement;
	}

	// Entity frames

	/// Starts reading `entity`'s replacement text; reading resumes at `resume` when it ends.
	Result<void, XmlFailure> PushFrame(XmlEntity entity, int refStart, int resume)
	{
		if (entity.mExpanding)
			return .Err(Fail(.RecursiveEntity, scope $"The entity `{entity.mName}` refers to itself", refStart, resume - refStart));
		if (mConfig.MaxEntityDepth > 0 && mFrames.Count >= mConfig.MaxEntityDepth)
			return .Err(Fail(.ResourceLimitExceeded, scope $"Entity references are nested deeper than MaxEntityDepth ({mConfig.MaxEntityDepth})", refStart, resume - refStart));
		Try!(CountExpansion(entity.mValue.Length, refStart, resume - refStart));
		InputFrame frame;
		frame.mData = mData;
		frame.mBase = mBase;
		frame.mPos = resume;
		frame.mEnd = mEnd;
		frame.mEntity = entity;
		frame.mElements = (int32)mElements.Count;
		if (mFrames.Count == 0)
		{
			frame.mRefOffset = (int32)refStart;
			frame.mRefLength = (int32)(resume - refStart);
		}
		else
		{
			frame.mRefOffset = mFrames[0].mRefOffset;
			frame.mRefLength = mFrames[0].mRefLength;
		}
		mFrames.Add(frame);
		entity.mExpanding = true;
		mData = entity.mValue.Ptr;
		mBase = 0;
		mPos = 0;
		mEnd = entity.mValue.Length;
		return .Ok;
	}

	/// Ends the innermost entity's replacement text, which must have closed every element it opened.
	Result<void, XmlFailure> PopFrame()
	{
		InputFrame frame = mFrames.Back;
		if (mElements.Count > frame.mElements)
		{
			let open = mElements.Back;
			return .Err(Fail(.UnclosedElement, scope $"The element `{mNames[open.mName]}` starts in the entity `{frame.mEntity.mName}` but does not end in it", mPos));
		}
		mFrames.PopBack();
		frame.mEntity.mExpanding = false;
		mData = frame.mData;
		mBase = frame.mBase;
		mPos = frame.mPos;
		mEnd = frame.mEnd;
		return .Ok;
	}

	/// Counts `bytes` of expansion against MaxEntityExpansionBytes and the amplification ratio.
	Result<void, XmlFailure> CountExpansion(int bytes, int refStart, int refLength)
	{
		mExpandedBytes += bytes;
		if (mConfig.MaxEntityExpansionBytes > 0 && mExpandedBytes > mConfig.MaxEntityExpansionBytes)
			return .Err(Fail(.ResourceLimitExceeded, scope $"Entity expansion produces more than MaxEntityExpansionBytes ({mConfig.MaxEntityExpansionBytes})", refStart, refLength));
		if (mConfig.MaxEntityAmplification > 0 && mExpandedBytes > mConfig.EntityAmplificationThreshold &&
			mExpandedBytes / Math.Max(mCursor.InputBytes, 1) >= mConfig.MaxEntityAmplification)
			return .Err(Fail(.ResourceLimitExceeded, scope $"Entity expansion produces more than MaxEntityAmplification ({mConfig.MaxEntityAmplification}) times the input's size", refStart, refLength));
		return .Ok;
	}

	/// Whether an undeclared general entity is a well-formedness error (§4.1 WFC Entity Declared): no
	/// DTD, an internal subset without parameter-entity references and no external subset, or
	/// `standalone="yes"`. Otherwise it is only a validity error and the reference is reported as skipped.
	bool EntityDeclaredIsWfc
	{
		get
		{
			if (!mDtd.mPresent || mStandalone == .Yes)
				return true;
			if (mConfig.DtdMode == .Ignore)
				return false;
			return !mDtd.mHasExternalSubset && !mDtd.mHasParameterReferences;
		}
	}

	/// Whether declarations are applied: not after an unread parameter entity unless standalone (§5.1).
	bool ProcessDeclarations => mConfig.DtdMode == .Internal && (!mDtd.mSkippedParameterEntity || mStandalone == .Yes);

	// The window

	/// Whether the byte at `pos` is available, reading more of a stream if needed. False at the end of
	/// an entity's replacement text.
	[Inline]
	bool Avail(int pos)
	{
		return pos < mEnd || Grow(pos, 1);
	}

	/// Whether `count` bytes from `pos` are available.
	[Inline]
	bool AvailN(int pos, int count)
	{
		return pos + count <= mEnd || Grow(pos, count);
	}

	/// Asks the cursor for more input, keeping the current construct. Never inside an entity frame
	/// (replacement text is whole). Inlined so that for in-memory input it folds to `false`.
	[Inline]
	bool Grow(int pos, int count)
	{
		if (mFrames.Count > 0)
			return false;
		bool grew = mCursor.Fill(ref mData, ref mBase, ref mEnd, Math.Min(Math.Min(mRetain, mPos), pos), pos, count);
		if (!grew)
		{
			if (mCursor.HasInputError)
				mInputFailed = true;
			return false;
		}
		return pos + count <= mEnd;
	}

	/// The byte at `pos`, or 0 if there is none.
	[Inline]
	char8 At(int pos)
	{
		return Avail(pos) ? mData[pos] : 0;
	}

	/// Whether `literal` is at `pos`.
	[Inline]
	bool StartsWith(int pos, StringView literal)
	{
		return AvailN(pos, literal.Length) && Internal.MemCmp(mData + pos, literal.Ptr, literal.Length) == 0;
	}

	[Inline]
	StringView View(int start, int length)
	{
		return StringView(mData + start, length);
	}

	/// Skips `S` (space, tab, LF, CR). @return The position after it.
	[Inline]
	int SkipSpace(int pos)
	{
		int p = pos;
		while (true)
		{
			if (p >= mEnd)
			{
				mPos = p;
				if (!Grow(p, 1))
					return p;
			}
			char8 c = mData[p];
			if (c != ' ' && c != '\n' && c != '\t' && c != '\r')
				return p;
			p++;
		}
	}

	/// The code point at `pos` (which must be available) and its length.
	[Inline]
	char32 DecodeAt(int pos, out int length)
	{
		if ((uint8)mData[pos] < 0x80)
		{
			length = 1;
			return (char32)mData[pos];
		}
		AvailN(pos, 4);
		return XmlChar.Decode(mData, pos, out length);
	}

	/// Scans a Name ([5]) at `pos`. @return Its end, or an error naming what was expected there.
	Result<int, XmlFailure> ScanName(int pos, StringView expected)
	{
		int p = pos;
		if (!Avail(p))
			return .Err(Unexpected(p, expected));
		uint8 cls = XmlChar.NameByteClass(mData[p]);
		if (cls == XmlChar.cNameStart)
			p++;
		else if (cls == XmlChar.cNameDecode && XmlChar.IsNameStartChar(DecodeAt(p, let length)))
			p += length;
		else
			return .Err(Unexpected(p, expected));
		while (true)
		{
			if (p >= mEnd && !Grow(p, 1))
				break;
			cls = XmlChar.NameByteClass(mData[p]);
			if (cls == XmlChar.cNameStart || cls == XmlChar.cNameOnly)
			{
				p++;
				continue;
			}
			if (cls == XmlChar.cNameDecode && XmlChar.IsNameChar(DecodeAt(p, let length)))
			{
				p += length;
				continue;
			}
			break;
		}
		if (mConfig.MaxNameBytes > 0 && p - pos > mConfig.MaxNameBytes)
			return .Err(Fail(.ResourceLimitExceeded, scope $"A name is longer than MaxNameBytes ({mConfig.MaxNameBytes})", pos, p - pos));
		return p;
	}

	/// Whether a name character is at `pos` (so a name read before it did not end there).
	bool IsNameCharAt(int pos)
	{
		if (!Avail(pos))
			return false;
		uint8 cls = XmlChar.NameByteClass(mData[pos]);
		if (cls == XmlChar.cNameDecode)
			return XmlChar.IsNameChar(DecodeAt(pos, let length));
		return cls != XmlChar.cNameStop;
	}

	/// With namespaces: an entity name, PI target or notation name must not contain a colon.
	Result<void, XmlFailure> CheckNoColon(int start, int end, StringView what)
	{
		if (!mConfig.Namespaces)
			return .Ok;
		let name = View(start, end - start);
		if (name.IndexOf(':') >= 0)
			return .Err(Fail(.InvalidQName, scope $"{what} `{name}` contains a colon, which namespaces do not allow", start, end - start));
		return .Ok;
	}

	// Errors

	/// Records the error (Next reports it) and returns the token internal methods fail with. Inside an
	/// entity's replacement text it is located at the outermost reference, and names the entity.
	XmlFailure Fail(XmlErrorKind kind, StringView message, int offset, int length = 1)
	{
		if (mInputFailed && mCursor.TryGetInputError(let inputError))
		{
			mError = inputError;
		}
		else
		{
			int docOffset = offset;
			int docLength = length;
			let text = scope String(message);
			if (mFrames.Count > 0)
			{
				docOffset = mFrames[0].mRefOffset;
				docLength = mFrames[0].mRefLength;
				text.AppendF(" (in the replacement text of the entity `{}`)", mFrames.Back.mEntity.mName);
			}
			int line = 0;
			int column = 0;
			if (mCursor.Locate(docOffset, var l, var c))
			{
				line = l;
				column = c;
			}
			mError = XmlParseError(kind, text, line, column, docOffset, docLength);
		}
		if (!mConfig.SourceName.IsEmpty)
			mError.SetSource(mConfig.SourceName);
		return .();
	}

	/// "Expected X, found Y" at `pos`.
	XmlFailure Unexpected(int pos, StringView expected)
	{
		let message = scope String();
		message.Append("Expected ");
		message.Append(expected);
		message.Append(", found ");
		if (!Avail(pos))
		{
			message.Append(mFrames.Count > 0 ? "the end of the entity" : "the end of the input");
			return Fail(.UnexpectedEof, message, pos, 0);
		}
		char32 cp = DecodeAt(pos, let length);
		if ((uint32)cp <= 0x20)
		{
			switch (cp)
			{
			case ' ': message.Append("a space");
			case '\t': message.Append("a tab");
			case '\n', '\r': message.Append("a newline");
			default: XmlChar.AppendCodePointName(message, (uint32)cp);
			}
		}
		else
		{
			message.Append('`');
			message.Append(View(pos, length));
			message.Append('`');
		}
		return Fail(.UnexpectedChar, message, pos, length);
	}
}
