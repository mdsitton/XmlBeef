using System;
using internal XmlBeef;

namespace XmlBeef;

/// Where XmlReaderCore's bytes come from (KdlBeef's IKdlCursor). The reader reads a window of the input
/// through a pointer `data` indexed by absolute offsets (`data[offset]`, valid for
/// `windowStart <= offset < end`), so offsets it keeps stay valid when a stream moves or grows its
/// buffer; only `data`, `windowStart` and `end` change. The bytes are UTF-8 checked by
/// XmlChar.FindInvalid, transcoded first when the document is in another encoding.
internal interface IXmlCursor
{
	/// Detects the encoding, validates what it can up front (all of an in-memory input) and sets up the
	/// window. @return The offset of the first content byte (after a BOM), or the input's error.
	Result<int, XmlParseError> Begin(ref char8* data, ref int windowStart, ref int end) mut;

	/// Makes the input up to `pos + count` available if there is that much, keeping every byte from
	/// `keep` on in the window (the reader's current construct). The window may move.
	/// @return Whether `end` grew.
	bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut;

	/// An error of the input itself (I/O, encoding, size) that stopped Fill.
	bool TryGetInputError(out XmlParseError error);

	/// Whether the input has failed (TryGetInputError would make an error), without making one.
	bool HasInputError { get; }

	/// The 1-based line and column (in code points) of `offset`: always for in-memory input; for a
	/// stream only from the earliest offset it still counts (the start of the current construct).
	bool Locate(int offset, out int line, out int column) mut;

	/// Whether Locate only works forward (streams): positions an error may need later, such as an open
	/// element's start, must then be located when they are read.
	bool LocatesOnlyForward { get; }

	/// The encoding the document was read in (after Begin).
	XmlEncoding Encoding { get; }

	/// Whether a UTF-8 byte order mark overrode a declaration of an 8-bit encoding (after Begin).
	bool BomOverridesDeclaration { get; }
}

/// Counts lines forward through the input, and columns only when asked: newlines are found 8 bytes at
/// a time up to an offset (AdvanceLines), and a column is the code points from a base on the current
/// line (its start, or a later offset whose column is known) to the offset (Column). A stream locates
/// only the elements still open when its buffer moves (XmlReaderCore.ResolvePositions), errors, and the
/// bytes it drops, so most bytes are only scanned for newlines, once.
internal struct XmlLineCounter
{
	/// Newlines are counted up to here.
	public int mPos;
	public int mLine = 1;
	/// The column base: an offset on the current line (its start, or later) and its column.
	public int mLineStart;
	public int mLineColumn = 1;

	public this(int start)
	{
		mPos = start;
		mLineStart = start;
	}

	/// Moves to `offset` (not before the current position), counting every newline (CRLF as one).
	/// `text[mPos ..< offset]` must be available, up to `end`.
	public void AdvanceLines(char8* text, int offset, int end) mut
	{
		while (mPos < offset)
		{
			// Two words at a time while neither has a byte below 0x0E: validated text has none there but tab,
			// LF and CR, so no newline (a word with a tab takes the exact path below)
			while (mPos + 16 <= offset && (XmlChar.BytesBelow0E(XmlChar.Load64(text + mPos)) | XmlChar.BytesBelow0E(XmlChar.Load64(text + mPos + 8))) == 0)
				mPos += 16;
			if (mPos >= offset)
				break;
			if (mPos + 8 <= end)
			{
				// Every newline of the word at once: each LF, and each CR not followed by an LF (in the word,
				// or the next byte), which then is the newline. A word past `offset` (still in the window)
				// counts only the bytes before it.
				int count = Math.Min(offset - mPos, 8);
				uint64 word = XmlChar.Load64(text + mPos);
				uint64 lf = XmlChar.BytesEqual(word, (uint8)'\n');
				uint64 cr = XmlChar.BytesEqual(word, (uint8)'\r');
				if ((lf | cr) != 0)
				{
					uint64 lfNext = lf >> 8;
					if (mPos + 8 < end && text[mPos + 8] == '\n')
						lfNext |= 1UL << 63;
					uint64 newlines = lf | (cr & ~lfNext);
					if (count < 8)
						newlines &= (1UL << (count * 8)) - 1;
					if (newlines != 0)
					{
						mLine += XmlChar.CountHighBits(newlines);
						// The line starts after the last one: smeared down, its byte and those below
						uint64 below = newlines | (newlines >> 8);
						below |= below >> 16;
						below |= below >> 32;
						mLineStart = mPos + XmlChar.CountHighBits(below);
						mLineColumn = 1;
					}
				}
				mPos += count;
				continue;
			}
			int newline = XmlChar.NewlineLength(text, mPos, end);
			// A CRLF across `offset` (an offset on its LF): its CR is not the newline, as in a word above;
			// the LF is counted from there
			if (mPos + newline > offset)
			{
				mPos = offset;
				break;
			}
			if (newline > 0)
			{
				mPos += newline;
				mLine++;
				mLineStart = mPos;
				mLineColumn = 1;
				continue;
			}
			mPos++;
		}
	}

	/// The column of `offset`, which must be on the current line, at or after the base, with
	/// `text[mLineStart ..< offset]` available. The base moves there, so the next column on the line
	/// counts on from it. (An offset inside a CRLF, before the base, gets the base's column.)
	public int Column(char8* text, int offset) mut
	{
		if (offset > mLineStart)
		{
			mLineColumn += XmlChar.CountCodePoints(text, mLineStart, offset);
			mLineStart = offset;
		}
		return mLineColumn;
	}

	/// AdvanceLines and Column: the line and column of `offset`.
	public void Locate(char8* text, int offset, int end, out int line, out int column) mut
	{
		AdvanceLines(text, offset, end);
		line = mLine;
		column = Column(text, offset);
	}
}

/// An in-memory input: the window is the whole (transcoded) input, validated up front; Fill never has
/// more.
internal struct XmlByteCursor : IXmlCursor
{
	StringView mInput;
	StringView mText;
	/// Receives the UTF-8 text of a document in another encoding (owned by the reader).
	String mTranscoded;
	XmlReadConfig mConfig;
	int mMaxInputBytes;
	XmlLineCounter mLines;
	XmlEncoding mEncoding;
	bool mBomOverride;

	public this(StringView input, String transcoded, XmlReadConfig config)
	{
		mBomOverride = false;
		mInput = input;
		mText = input;
		mTranscoded = transcoded;
		mConfig = config;
		mMaxInputBytes = config.MaxInputBytes;
		mLines = .(0);
		mEncoding = .Utf8;
	}

	public Result<int, XmlParseError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		data = mInput.Ptr;
		windowStart = 0;
		end = 0;
		if (mMaxInputBytes > 0 && mInput.Length > mMaxInputBytes)
			return .Err(XmlParseError(.ResourceLimitExceeded, scope $"The input ({mInput.Length} bytes) exceeds MaxInputBytes ({mMaxInputBytes})", 1, 1, 0, 0));
		int start = 0;
		if (XmlEncodingDetector.Prepare(mInput, mTranscoded, mConfig, out mText, out start, out mEncoding, out mBomOverride) case .Err(let error))
			return .Err(error);
		data = mText.Ptr;
		end = mText.Length;
		mLines = .(start);
		let message = scope String();
		int bad = XmlChar.FindInvalid(mText.Ptr, start, mText.Length, message, let kind, let length);
		if (bad >= 0)
		{
			Locate(bad, let line, let column);
			return .Err(XmlParseError(kind, message, line, column, bad, length));
		}
		return start;
	}

	[Inline]
	public bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut
	{
		return false;
	}

	[Inline]
	public bool TryGetInputError(out XmlParseError error)
	{
		error = default;
		return false;
	}

	public bool HasInputError
	{
		[Inline]
		get => false;
	}

	public XmlEncoding Encoding => mEncoding;

	public bool BomOverridesDeclaration => mBomOverride;

	/// The UTF-8 text the reader's offsets index (after Begin): the input, or its transcoding.
	public StringView Text => mText;

	public bool LocatesOnlyForward
	{
		[Inline]
		get => false;
	}

	public bool Locate(int offset, out int line, out int column) mut
	{
		int target = Math.Min(offset, mText.Length);
		if (target < mLines.mPos)
		{
			// Behind the counter (an error before the last position asked for): count from the start
			XmlChar.LineAndColumn(mText, target, out line, out column);
			return true;
		}
		mLines.Locate(mText.Ptr, target, mText.Length, out line, out column);
		return true;
	}
}
