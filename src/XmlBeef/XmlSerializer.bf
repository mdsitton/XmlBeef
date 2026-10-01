using System;
using System.Collections;

namespace XmlBeef;

/// @brief One-call reading and writing of whole documents as [XmlObject] types (see
/// XmlObjectAttribute): the object is the root element, which must have its type's element name. Each
/// call is a scoped XmlDocument, its Read/ReadFile or Write, and the object's XmlRead or XmlWrite on
/// the root. Use the document API directly to bind an object to any element (`obj.XmlRead(node)`), mix
/// typed and hand-written data, or update a document read with PreserveStyle in place
/// (`obj.XmlWrite(doc.Root)`, then `doc.WriteFile`).
public static class XmlSerializer
{
	/// @brief Parse `text` and fill `target` from its root element. Errors (parse errors, a root of
	/// another type, missing required values, wrong values) are located in the source.
	/// @param text The XML document.
	/// @param target The object to fill; fields whose values are absent keep theirs.
	/// @param config Read settings; metadata below Positions is raised to Positions, for error locations.
	/// @param allocator Where created Strings, objects and Lists come from (for example a
	/// `scope BumpAllocator`), or null for the heap, when the object owns them.
	/// @return .Ok, or the first error.
	public static Result<void, XmlParseError> Read<T>(StringView text, T target, XmlReadConfig config = .(), ITypedAllocator allocator = null) where T : class, IXmlSerializable
	{
		let doc = scope XmlDocument();
		Try!(Detached(doc.Read(text, WithPositions(config))));
		Try!(Detached(XmlBind.CheckRoot(doc.Root, target.XmlElementName, target.XmlElementNamespace)));
		return Detached(target.XmlRead(doc.Root, allocator));
	}

	/// @brief Parse `text` and fill the struct `target`; see the class overload.
	/// @param text The XML document.
	/// @param target The struct to fill.
	/// @param config Read settings.
	/// @param allocator Where created objects come from, or null for the heap.
	/// @return .Ok, or the first error.
	public static Result<void, XmlParseError> Read<T>(StringView text, ref T target, XmlReadConfig config = .(), ITypedAllocator allocator = null) where T : struct, IXmlSerializable
	{
		let doc = scope XmlDocument();
		Try!(Detached(doc.Read(text, WithPositions(config))));
		Try!(Detached(XmlBind.CheckRoot(doc.Root, target.XmlElementName, target.XmlElementNamespace)));
		return Detached(target.XmlRead(doc.Root, allocator));
	}

	/// @brief Parse the file at `path` and fill `target`. Errors name the file:
	/// `icon.svg:3:8: rect: width: expected a number, found `wide``.
	/// @param path The file to read.
	/// @param target The object to fill.
	/// @param config Read settings.
	/// @param allocator Where created objects come from, or null for the heap.
	/// @return .Ok, or the first error.
	public static Result<void, XmlParseError> ReadFile<T>(StringView path, T target, XmlReadConfig config = .(), ITypedAllocator allocator = null) where T : class, IXmlSerializable
	{
		let doc = scope XmlDocument();
		Try!(Detached(doc.ReadFile(path, WithPositions(config))));
		Try!(Detached(XmlBind.CheckRoot(doc.Root, target.XmlElementName, target.XmlElementNamespace)));
		return Detached(target.XmlRead(doc.Root, allocator));
	}

	/// @brief Write `source` as a new document (its root element, in canonical form), appending to
	/// `output`.
	/// @param source The object to write.
	/// @param output Receives the XML text.
	/// @param options Indentation.
	/// @return .Ok, or an error.
	public static Result<void, XmlParseError> Write<T>(T source, String output, XmlWriteOptions options = .()) where T : IXmlSerializable
	{
		let doc = scope XmlDocument();
		Try!(Fill(doc, source));
		doc.WriteCanonical(output, options);
		return .Ok;
	}

	/// @brief Write `source` as a new document to the file at `path` (UTF-8), replacing it. To update an
	/// existing file and keep its formatting, read it with PreserveStyle and use XmlWrite on its Root.
	/// @param source The object to write.
	/// @param path The file to write.
	/// @param options Indentation.
	/// @return .Ok, or an error (IoError if the file cannot be written).
	public static Result<void, XmlParseError> WriteFile<T>(T source, StringView path, XmlWriteOptions options = .()) where T : IXmlSerializable
	{
		let output = scope String();
		Try!(Write(source, output, options));
		if (System.IO.File.WriteAllText(path, output) case .Err)
		{
			var error = XmlParseError(.IoError, "Cannot write the file", 0, 0, 0, 0);
			error.SetSource(path);
			return .Err(error);
		}
		return .Ok;
	}

	/// The root element for `source`, declaring its namespace, then its fields.
	static Result<void, XmlParseError> Fill<T>(XmlDocument doc, T source) where T : IXmlSerializable
	{
		let root = doc.DocumentNode.AddElement(source.XmlElementName);
		if (!source.XmlElementNamespace.IsEmpty)
			root.SetAttribute("xmlns", source.XmlElementNamespace);
		return source.XmlWrite(root);
	}

	/// An error made independent of the scoped document about to be destroyed: its message and source
	/// name are copied to the per-thread buffer.
	static Result<void, XmlParseError> Detached(Result<void, XmlParseError> result)
	{
		if (result case .Err(var error))
		{
			error.Detach();
			return .Err(error);
		}
		return .Ok;
	}

	static XmlReadConfig WithPositions(XmlReadConfig config)
	{
		var config;
		if (config.MetadataMode == .None)
			config.MetadataMode = .Positions;
		return config;
	}
}
