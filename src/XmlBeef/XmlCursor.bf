using System;
using System.IO;
using FormatCore;
using internal FormatCore;
using internal XmlBeef;

namespace XmlBeef;

/// Where XmlReaderCore's bytes come from: FormatCore's window protocol (`IInputCursor`: the reader reads
/// a window of the input through a pointer `data` indexed by absolute offsets, valid for
/// `windowStart <= offset < end`, so offsets it keeps stay valid when a stream moves or grows its
/// buffer) with XML's errors and what the reader reports about the encoding. The two cursors are thin
/// adapters over FormatCore's transcoding cursors (detection by XmlDetector, validation by XmlText); every
/// member is inlined into the core.
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

/// Counts lines forward through the input, and columns only when asked (FormatCore's LineCounter, which
/// started as XmlBeef's).
typealias XmlLineCounter = LineCounter<XmlText>;

/// What a stream read owns (FormatCore's TranscodingState: the UTF-8 window buffer, the raw bytes, the
/// whole input's transcoding when a converter or the fallback needs it, and the input's error).
typealias XmlStreamState = TranscodingState;

/// The cursor-level settings of a read config, and its error conversion.
internal static class XmlInput
{
	/// @brief FormatCore's cursor settings for `config`.
	[Inline]
	public static InputSettings Settings(XmlReadConfig config)
	{
		InputSettings settings = default;
		settings.mMaxInputBytes = config.MaxInputBytes;
		settings.mMaxTokenBytes = config.MaxTokenBytes;
		settings.mStreamBufferBytes = config.StreamBufferBytes;
		// UTF-16 and UTF-32 are detected and decoded (XmlDetector), not rejected
		settings.mIgnoreWideEncodings = true;
		settings.mFormatName = "XML";
		return settings;
	}

	/// @brief The converter and the fallback of `config`.
	[Inline]
	public static TranscodeSettings Transcode(XmlReadConfig config)
	{
		TranscodeSettings transcode = default;
		transcode.mConverter = config.EncodingConverter;
		transcode.mFallback = config.EncodingFallback;
		return transcode;
	}

	/// @brief An input error as XML's (the message copied into XmlParseError's buffer).
	public static XmlParseError Error(InputError error)
	{
		return XmlParseError(XmlText.MapKind(error.mKind), error.mMessage, error.mLine, error.mColumn, error.mOffset, error.mLength);
	}
}

/// An in-memory input: the window is the whole (transcoded) input, validated up front; Fill never has
/// more (FormatCore's TranscodingByteCursor).
internal struct XmlByteCursor : IXmlCursor
{
	TranscodingByteCursor<XmlText, XmlDetector> mInner;

	/// @brief A cursor over `input`.
	/// @param input The document's bytes.
	/// @param state Receives the UTF-8 text of a document in another encoding (owned by the reader).
	/// @param config The read config.
	public this(StringView input, XmlStreamState state, XmlReadConfig config)
	{
		mInner = .(input, state, XmlInput.Settings(config), XmlInput.Transcode(config));
	}

	public Result<int, XmlParseError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		switch (mInner.Begin(ref data, ref windowStart, ref end))
		{
		case .Ok(let start):
			return start;
		case .Err(let error):
			return .Err(XmlInput.Error(error));
		}
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

	public XmlEncoding Encoding => mInner.Encoding;

	public bool BomOverridesDeclaration => mInner.Detection.mBomOverride;

	/// The UTF-8 text the reader's offsets index (after Begin): the input, or its transcoding.
	public StringView Text => mInner.Text;

	public bool LocatesOnlyForward
	{
		[Inline]
		get => false;
	}

	[Inline]
	public bool Locate(int offset, out int line, out int column) mut
	{
		return mInner.Locate(offset, out line, out column);
	}
}

/// A stream read through a buffer (FormatCore's TranscodingStreamCursor): the window is the decoded part
/// of the input from the reader's current construct on. The encoding is detected from the stream's first
/// XmlDetector.cPrefixBytes (more while the declaration goes on); the rest is decoded as it arrives, so
/// offsets are UTF-8 offsets exactly as for the same document in memory. A converter or the Windows-1252
/// fallback needs the whole input at once: the stream is then read to its end first.
internal struct XmlBufferedStreamCursor : IXmlCursor
{
	TranscodingStreamCursor<XmlText, XmlDetector> mInner;

	/// @brief A cursor over `stream`.
	/// @param stream The stream.
	/// @param state The buffers and error storage (reused across reads).
	/// @param config The read config.
	public this(Stream stream, XmlStreamState state, XmlReadConfig config)
	{
		mInner = .(stream, state, XmlInput.Settings(config), XmlInput.Transcode(config));
	}

	public Result<int, XmlParseError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		switch (mInner.Begin(ref data, ref windowStart, ref end))
		{
		case .Ok(let start):
			return start;
		case .Err(let error):
			return .Err(XmlInput.Error(error));
		}
	}

	[Inline]
	public bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut
	{
		return mInner.Fill(ref data, ref windowStart, ref end, keep, pos, count);
	}

	public bool TryGetInputError(out XmlParseError error)
	{
		if (mInner.TryGetInputError(let inputError))
		{
			error = XmlInput.Error(inputError);
			return true;
		}
		error = default;
		return false;
	}

	public bool HasInputError
	{
		[Inline]
		get => mInner.HasInputError;
	}

	public XmlEncoding Encoding => mInner.Encoding;

	public bool BomOverridesDeclaration => mInner.Detection.mBomOverride;

	public bool LocatesOnlyForward
	{
		[Inline]
		get => true;
	}

	[Inline]
	public bool Locate(int offset, out int line, out int column) mut
	{
		return mInner.Locate(offset, out line, out column);
	}
}
