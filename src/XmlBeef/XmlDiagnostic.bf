using System;

namespace XmlBeef;

/// @brief An error that owns its text, for keeping it: a list of diagnostics, errors from several
/// readers, documents or threads. (An XmlParseError's message views a per-thread buffer that the next
/// error on the thread replaces; a document's collected errors live until it is cleared or read again.)
/// Delete it when done.
///
/// ```
/// let kept = new List<XmlDiagnostic>();
/// defer { DeleteContainerAndItems!(kept); }
/// for (let path in paths)
/// {
///     if (doc.ReadFile(path) case .Err(let error))
///         kept.Add(new XmlDiagnostic(error));
/// }
/// ```
public class XmlDiagnostic
{
	/// @brief The category of error.
	public XmlErrorKind mKind;
	/// @brief Human-readable description.
	public String mMessage ~ delete _;
	/// @brief Name of the input the position refers to; empty if unnamed.
	public String mSource ~ delete _;
	/// @brief 1-based line (0 when there is no position).
	public int32 mLine;
	/// @brief 1-based column, in code points.
	public int32 mColumn;
	/// @brief Byte offset into the input.
	public int32 mOffset;
	/// @brief Length of the erroneous span in bytes.
	public int32 mLength;

	/// @brief Copy an error.
	/// @param error The error (its text is copied, so it may be the last one of its thread).
	public this(XmlParseError error)
	{
		mKind = error.mKind;
		mMessage = new String(error.mMessage);
		mSource = new String(error.mSource);
		mLine = error.mLine;
		mColumn = error.mColumn;
		mOffset = error.mOffset;
		mLength = error.mLength;
	}

	/// @brief The diagnostic as an XmlParseError whose text views this object (valid while it lives).
	public XmlParseError Error
	{
		get
		{
			XmlParseError error = default;
			error.mKind = mKind;
			error.mMessage = mMessage;
			error.mSource = mSource;
			error.mLine = mLine;
			error.mColumn = mColumn;
			error.mOffset = mOffset;
			error.mLength = mLength;
			return error;
		}
	}

	/// @brief Formats the diagnostic as XmlParseError.ToString does (`source:line:column: message`).
	/// @param strBuffer The string to append to.
	public override void ToString(String strBuffer)
	{
		Error.ToString(strBuffer);
	}
}
