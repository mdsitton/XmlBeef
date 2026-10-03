using System;
using FormatCore;

namespace XmlBeef;

/// @brief An error that owns its text, for keeping it: a list of diagnostics, errors from several
/// readers, documents or threads (FormatCore's `Diagnostic` over XmlErrorKind). An XmlParseError's
/// message views a per-thread buffer that the next error on the thread replaces; a document's collected
/// errors live until it is cleared or read again. Delete it when done.
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
public typealias XmlDiagnostic = FormatCore.Diagnostic<XmlErrorKind>;
