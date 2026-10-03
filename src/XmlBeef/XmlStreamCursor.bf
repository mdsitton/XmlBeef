using System;
using System.Collections;
using System.IO;
using internal XmlBeef;

namespace XmlBeef;

/// What a stream read owns (a cursor is a struct): the UTF-8 window's buffer, the raw bytes read but not
/// decoded yet, and the input's error. The error is kept in parts, with its own copy of the message: an
/// XmlParseError's message lives in a per-thread buffer that the next error overwrites.
internal class XmlStreamState
{
	public List<uint8> mBuffer ~ delete _;
	public List<uint8> mRaw ~ delete _;
	public String mWhole ~ delete _;
	public String mDeclared ~ delete _;
	public String mScratch ~ delete _;
	public bool mHasError;
	public XmlErrorKind mErrorKind;
	public String mErrorMessage ~ delete _;
	public int mErrorLine;
	public int mErrorColumn;
	public int mErrorOffset;
	public int mErrorLength;

	public this()
	{
		mBuffer = new .();
		mRaw = new .();
		mWhole = new .();
		mDeclared = new .();
		mScratch = new .();
		mErrorMessage = new .();
	}

	public XmlParseError MakeError()
	{
		return XmlParseError(mErrorKind, mErrorMessage, mErrorLine, mErrorColumn, mErrorOffset, mErrorLength);
	}
}

/// A stream read through a buffer (KdlBeef's KdlBufferedStreamCursor, with encodings): the window is the
/// decoded (UTF-8) part of the input from the reader's current construct on. The encoding is detected
/// from the stream's first XmlEncodingDetector.cPrefixBytes; the rest is decoded as it arrives (a code
/// unit cut off at a read's end waits for the next), so offsets are in UTF-8 terms exactly as for the
/// same document in memory. A converter (XmlReadConfig.EncodingConverter) or the Windows-1252 fallback
/// needs the whole input at once: then the stream is read to its end first.
///
/// A refill drops the bytes before the reader's construct and moves the rest to the front; a construct
/// longer than the buffer doubles it (bounded by MaxTokenBytes). Bytes are validated as they arrive; the
/// window ends at the last complete, valid code point, so the reader never sees bytes that are not.
internal struct XmlBufferedStreamCursor : IXmlCursor
{
	Stream mStream;
	XmlStreamState mState;
	XmlReadConfig mConfig;
	XmlDecoder mDecoder;
	XmlEncoding mEncoding;
	/// Absolute (UTF-8) offset of the buffer's first byte.
	int mBase;
	/// UTF-8 bytes in the buffer, and how many of them are validated (the window).
	int mFilled;
	int mValid;
	/// The first undecoded byte in mState.mRaw.
	int mRawStart;
	/// The stream is exhausted (raw bytes may still wait to be decoded).
	bool mEof;
	/// Nothing more will be decoded: the input is all in the buffer, or failed (mState.mHasError).
	bool mDone;
	int mBytesRead;
	int mMaxInputBytes;
	int mMaxTokenBytes;
	/// Lines counted up to the bytes dropped from the buffer: nothing before it can be located.
	XmlLineCounter mLines;
	/// Lines counted forward for Locate; a request behind it counts from mLines instead.
	XmlLineCounter mLocated;
	bool mBomOverride;

	public this(Stream stream, XmlStreamState state, XmlReadConfig config)
	{
		mStream = stream;
		mState = state;
		mConfig = config;
		mDecoder = XmlDecoder(.Utf8);
		mEncoding = .Utf8;
		mBase = 0;
		mFilled = 0;
		mValid = 0;
		mRawStart = 0;
		mEof = false;
		mDone = false;
		mBytesRead = 0;
		mMaxInputBytes = config.MaxInputBytes;
		mMaxTokenBytes = config.MaxTokenBytes;
		mLines = .(0);
		mLocated = .(0);
		mBomOverride = false;
		state.mHasError = false;
		state.mRaw.Clear();
		int size = config.StreamBufferBytes > 0 ? Math.Max(config.StreamBufferBytes, 16) : 64 * 1024;
		// Never more than MaxTokenBytes: a construct that would exceed it cannot fit the window, so reading
		// it always comes to Fill, which checks it
		if (mMaxTokenBytes > 0)
			size = Math.Min(size, Math.Max(mMaxTokenBytes, 16));
		state.mBuffer.Count = size;
	}

	[Inline]
	uint8* Buffer => mState.mBuffer.Ptr;

	public Result<int, XmlParseError> Begin(ref char8* data, ref int windowStart, ref int end) mut
	{
		data = (char8*)Buffer;
		windowStart = 0;
		end = 0;
		// Enough to detect the encoding (the whole input, if it is shorter)
		while (mState.mRaw.Count < XmlEncodingDetector.cPrefixBytes && !mEof)
		{
			if (!ReadRaw(XmlEncodingDetector.cPrefixBytes - mState.mRaw.Count))
				break;
		}
		if (mState.mHasError)
			return .Err(mState.MakeError());
		XmlDetection detection;
		while (true)
		{
			StringView prefix = .((char8*)mState.mRaw.Ptr, mState.mRaw.Count);
			switch (XmlEncodingDetector.Detect(prefix, mState.mDeclared, mState.mScratch))
			{
			case .Ok(let found):
				detection = found;
			case .Err(let error):
				return .Err(error);
			}
			// A declaration that goes on past the prefix: more of it, as memory input does
			if (!detection.mIncomplete || mEof)
				break;
			Try!(XmlEncodingDetector.CheckDeclarationLength(mState.mRaw.Count, mConfig));
			int target = mState.mRaw.Count * 2;
			while (mState.mRaw.Count < target && !mEof)
			{
				if (!ReadRaw(target - mState.mRaw.Count))
					break;
			}
			if (mState.mHasError)
				return .Err(mState.MakeError());
		}
		int start = detection.mUtf8Bom ? 3 : 0;
		mBomOverride = detection.mBomOverride;
		if (detection.mConvert || (detection.mUndeclared && mConfig.EncodingFallback != .None))
		{
			// The converter and the fallback take the whole input
			Try!(ReadWhole(ref start));
		}
		else
		{
			mEncoding = detection.mEncoding;
			mDecoder = XmlDecoder(mEncoding);
			mRawStart = detection.mSkip;
			// The whole input came with the detection prefix: check it all now, as for memory, so a small
			// document reports the same first error from a stream (read on through the buffer all the same)
			if (mEof)
				Try!(CheckWhole(start));
			// The first buffer, validated: a document that fits it reports the same first error as from memory
			while (mFilled < mState.mBuffer.Count && !mDone)
			{
				if (!ReadMore())
					break;
			}
		}
		mValid = start;
		mLines = .(start);
		mLocated = .(start);
		Validate();
		SetWindow(ref data, ref windowStart, ref end, start);
		if (mState.mHasError)
			return .Err(mState.MakeError());
		return start;
	}

	/// Decodes and validates the whole input (all in mState.mRaw) into scratch space, failing as the
	/// in-memory path would: the first encoding or character error, located in the decoded text.
	Result<void, XmlParseError> CheckWhole(int start) mut
	{
		let text = mState.mWhole;
		int length = mState.mRaw.Count - mRawStart;
		int capacity = length * mDecoder.MaxExpansion + 8;
		text.Clear();
		uint8* dst = (uint8*)text.PrepareBuffer(capacity);
		var decoder = mDecoder;
		bool ok = decoder.Decode(mState.mRaw.Ptr + mRawStart, length, true, dst, capacity, let consumed, let produced, let error);
		text.Length = produced;
		if (!ok)
			return .Err(XmlEncodingDetector.DecodeError(error, mEncoding, mState.mDeclared, (char8)mState.mRaw[mRawStart + consumed], text, produced));
		let message = scope String();
		int bad = XmlChar.FindInvalid(text.Ptr, start, text.Length, message, let kind, let badLength);
		if (bad >= 0)
		{
			XmlChar.LineAndColumn(text, bad, let line, let column);
			return .Err(XmlParseError(kind, message, line, column, bad, badLength));
		}
		return .Ok;
	}

	/// Reads the rest of the stream and converts it all at once (XmlEncodingDetector.Prepare), for the
	/// converter or the fallback.
	Result<void, XmlParseError> ReadWhole(ref int start) mut
	{
		while (!mEof)
		{
			if (!ReadRaw(64 * 1024))
				break;
		}
		if (mState.mHasError)
			return .Err(mState.MakeError());
		StringView input = .((char8*)mState.mRaw.Ptr, mState.mRaw.Count);
		if (XmlEncodingDetector.Prepare(input, mState.mWhole, mConfig, let text, out start, out mEncoding) case .Err(let error))
			return .Err(error);
		mState.mBuffer.Count = Math.Max(text.Length, mState.mBuffer.Count);
		Internal.MemCpy(Buffer, text.Ptr, text.Length);
		mFilled = text.Length;
		mDone = true;
		mEof = true;
		// The token limit still holds: SetWindow shows no more than MaxTokenBytes from the current
		// construct, so a longer one comes to Fill's check as from any stream
		return .Ok;
	}

	/// Reads once from the stream into mState.mRaw (at most `want` bytes). @return Whether anything came.
	bool ReadRaw(int want) mut
	{
		if (mEof)
			return false;
		// Drop what was decoded
		if (mRawStart > 0)
		{
			int left = mState.mRaw.Count - mRawStart;
			Internal.MemMove(mState.mRaw.Ptr, mState.mRaw.Ptr + mRawStart, left);
			mState.mRaw.Count = left;
			mRawStart = 0;
		}
		int count = mState.mRaw.Count;
		int chunk = Math.Max(want, 16);
		mState.mRaw.Count = count + chunk;
		switch (mStream.TryRead(.(mState.mRaw.Ptr + count, chunk)))
		{
		case .Ok(let read):
			mState.mRaw.Count = count + Math.Max(read, 0);
			if (read <= 0)
			{
				mEof = true;
				return false;
			}
			mBytesRead += read;
			if (mMaxInputBytes > 0 && mBytesRead > mMaxInputBytes)
			{
				SetError(.ResourceLimitExceeded, scope $"The input exceeds MaxInputBytes ({mMaxInputBytes})", mBase + mFilled, 0);
				mEof = true;
				return false;
			}
			return true;
		case .Err:
			mState.mRaw.Count = count;
			SetError(.IoError, "Reading the input failed", mBase + mFilled, 0);
			mEof = true;
			return false;
		}
	}

	/// Decodes more input into the buffer's free space, reading the stream as needed.
	/// @return Whether anything was added (false: the buffer is full, or the input ended or failed).
	bool ReadMore() mut
	{
		while (!mDone)
		{
			int free = mState.mBuffer.Count - mFilled;
			if (free < 4 && (mEncoding != .Utf8 || free == 0))
				return false;
			int pending = mState.mRaw.Count - mRawStart;
			if (pending > 0)
			{
				bool ok = mDecoder.Decode(mState.mRaw.Ptr + mRawStart, pending, mEof, Buffer + mFilled, free, let consumed, let produced, let error);
				mRawStart += consumed;
				mFilled += produced;
				if (!ok)
				{
					let message = scope String();
					if (mEncoding == .Ascii || (mEncoding >= .Latin1 && mEncoding != .Custom))
						message.AppendF("The byte 0x{:X2} is not defined in the encoding `{}`", mState.mRaw[mRawStart], mState.mDeclared);
					else
						message.Append(error);
					SetError(.InvalidEncoding, message, mBase + mFilled);
					return produced > 0;
				}
				if (produced > 0)
					return true;
				if (mEof)
				{
					mDone = true;
					return false;
				}
				// A code unit cut off at the end of what was read: read on
			}
			else if (mEof)
			{
				mDone = true;
				return false;
			}
			ReadRaw(Math.Max(free, 4096));
		}
		return false;
	}

	public bool Fill(ref char8* data, ref int windowStart, ref int end, int keep, int pos, int count) mut
	{
		int oldEnd = end;
		int from = Math.Min(keep, pos);
		// The construct from `from` through what the reader looks at is what MaxTokenBytes bounds, when
		// those bytes exist (in the buffer, or maybe still in the stream)
		if (mMaxTokenBytes > 0 && pos + count - from > mMaxTokenBytes && (pos + count <= mBase + mValid || !mDone))
		{
			SetError(.ResourceLimitExceeded, scope $"A construct is longer than MaxTokenBytes ({mMaxTokenBytes})", from + mMaxTokenBytes);
			SetWindow(ref data, ref windowStart, ref end, from);
			return false;
		}
		while (mBase + mValid < pos + count)
		{
			// Nothing more will come (the end, or an error: the window stops at the error)
			if (mDone)
				break;
			// Drop what the reader is done with, counting its lines first; never just after a CR (an LF
			// may follow, and the two halves of a CRLF would count as two newlines)
			int drop = Math.Min(keep, pos) - mBase;
			if (drop > 0 && Buffer[drop - 1] == (uint8)'\r')
				drop--;
			if (drop > 0)
			{
				// From Locate's count when it is not past the drop (it never is behind mLines): the bytes
				// before it are not counted again. Both counters' column bases move up to the drop, whose
				// bytes are about to go.
				char8* text = (char8*)Buffer - mBase;
				int dropTo = mBase + drop;
				if (mLocated.mPos <= dropTo)
				{
					mLocated.AdvanceLines(text, dropTo, mBase + mFilled);
					mLocated.Column(text, dropTo);
					mLines = mLocated;
				}
				else
				{
					mLines.AdvanceLines(text, Math.Max(dropTo, mLines.mPos), mBase + mFilled);
					mLines.Column(text, dropTo);
					if (mLocated.mLineStart < dropTo)
						mLocated.Column(text, dropTo);
				}
				Internal.MemMove(Buffer, Buffer + drop, mFilled - drop);
				mBase += drop;
				mFilled -= drop;
				mValid -= drop;
			}
			if (mState.mBuffer.Count - mFilled < 4)
			{
				// One construct fills the buffer: grow it, never past MaxTokenBytes
				if (mMaxTokenBytes > 0 && mFilled >= mMaxTokenBytes)
				{
					SetError(.ResourceLimitExceeded, scope $"A construct is longer than MaxTokenBytes ({mMaxTokenBytes})", mBase + mFilled);
					break;
				}
				int grown = mState.mBuffer.Count * 2;
				if (mMaxTokenBytes > 0)
					grown = Math.Min(grown, mMaxTokenBytes + 4);
				mState.mBuffer.Count = grown;
			}
			ReadMore();
			Validate();
		}
		SetWindow(ref data, ref windowStart, ref end, from);
		return end > oldEnd;
	}

	/// The window: the validated bytes, but with MaxTokenBytes no more than that from `from` (the
	/// construct being read), so a longer construct always comes to Fill's check.
	void SetWindow(ref char8* data, ref int windowStart, ref int end, int from)
	{
		data = (char8*)Buffer - mBase;
		windowStart = mBase;
		end = mBase + mValid;
		if (mMaxTokenBytes > 0 && from + mMaxTokenBytes < end)
			end = Math.Max(from + mMaxTokenBytes, mBase);
	}

	/// Validates the newly decoded bytes up to the last complete code point (all of them at the end of
	/// the input) and extends the window over them, or stops at the first invalid one.
	void Validate() mut
	{
		char8* text = (char8*)Buffer - mBase;
		int from = mBase + mValid;
		int to = mDone ? mBase + mFilled : FormatCore.Utf8.CompleteSequencesEnd(text, from, mBase + mFilled);
		if (mState.mHasError)
			to = Math.Min(to, Math.Max(mState.mErrorOffset, from));
		let message = scope String();
		int bad = XmlChar.FindInvalid(text, from, to, message, let kind, let length);
		if (bad >= 0)
		{
			mValid = bad - mBase;
			SetError(kind, message, bad, length);
			return;
		}
		mValid = to - mBase;
	}

	/// Records the input's first error and stops reading.
	void SetError(XmlErrorKind kind, StringView message, int offset, int length = 1) mut
	{
		mDone = true;
		if (mState.mHasError)
			return;
		Locate(offset, out mState.mErrorLine, out mState.mErrorColumn);
		mState.mErrorKind = kind;
		mState.mErrorMessage.Set(message);
		mState.mErrorOffset = offset;
		mState.mErrorLength = length;
		mState.mHasError = true;
	}

	public bool TryGetInputError(out XmlParseError error)
	{
		error = mState.mHasError ? mState.MakeError() : default;
		return mState.mHasError;
	}

	public bool HasInputError => mState.mHasError;

	public bool LocatesOnlyForward
	{
		[Inline]
		get => true;
	}

	public XmlEncoding Encoding => mEncoding;


	public bool BomOverridesDeclaration => mBomOverride;

	public bool Locate(int offset, out int line, out int column) mut
	{
		line = 0;
		column = 0;
		if (offset < mLines.mPos)
			return false;
		int target = Math.Min(offset, mBase + mFilled);
		char8* text = (char8*)Buffer - mBase;
		if (target >= mLocated.mPos)
		{
			mLocated.Locate(text, target, mBase + mFilled, out line, out column);
			return true;
		}
		// Behind the forward count (an error at an earlier offset): count from the dropped bytes
		var lines = mLines;
		lines.Locate(text, target, mBase + mFilled, out line, out column);
		return true;
	}
}
