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

/// Counts lines and columns forward through the input, one offset at a time.
internal struct XmlLineCounter
{
	public int mPos;
	public int mLine = 1;
	public int mColumn = 1;

	public this(int start)
	{
		mPos = start;
	}

	/// Moves to `offset` (not before the current position), counting every newline (CRLF as one) and
	/// every code point. `text[mPos ..< offset]` must be available, up to `end`.
	public void AdvanceTo(char8* text, int offset, int end) mut
	{
		while (mPos < offset)
		{
			int newline = XmlChar.NewlineLength(text, mPos, end);
			if (newline > 0)
			{
				mPos += newline;
				mLine++;
				mColumn = 1;
				continue;
			}
			mPos += Math.Max(XmlChar.Utf8SequenceLength(text[mPos]), 1);
			mColumn++;
		}
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
		mLines.AdvanceTo(mText.Ptr, target, mText.Length);
		line = mLines.mLine;
		column = mLines.mColumn;
		return true;
	}
}
