using System;

namespace XmlBeef;

/// @brief Generates XML reading and writing for a class or struct at compile time.
///
/// ```
/// [XmlObject(Name = "svg", Namespace = "http://www.w3.org/2000/svg")]
/// class Svg
/// {
/// 	public double width;                                        // width="100"
/// 	public String viewBox ~ delete _;                           // viewBox="0 0 10 10"
/// 	[XmlElement] public String title ~ delete _;                // <title>Icon</title>
/// 	[XmlChildren] public List<Shape> shapes ~ DeleteContainerAndItems!(_);   // <rect …/>, <circle …/>
/// }
/// ```
///
/// The type gets IXmlSerializable. Its public instance fields map to an element by role:
/// - scalars (bool, integers, float, double, String, enums, converter types; see IXmlConverter) are
///   attributes, or with [XmlElement] child elements holding the value as text (`<title>x</title>`),
///   or with [XmlText] the element's own text;
/// - [XmlAttribute] List<scalar>: one attribute holding the items separated by spaces (`class="a b"`);
/// - List<scalar>: repeated child elements named after the field (`<tag>a</tag><tag>b</tag>`);
/// - another [XmlObject] type: a child element named after the field;
/// - List<[XmlObject] type>: repeated child elements named after the item type (its Name);
/// - [XmlArray] on a List: the items inside a wrapper element (`<tags><tag>a</tag></tags>`);
/// - [XmlChildren] List<T>: every child element no other field claims, each read as the [XmlObject]
///   type assignable to T whose element name it has (found at compile time);
/// - Dictionary<K, V> (K a String, integer or enum; V a scalar or [XmlObject] type): a wrapper element
///   named after the field with one entry per key, named after the value's type, the key in an
///   attribute: `<limits><int32 name="retries">3</int32></limits>` (see XmlMap).
///
/// Names are the declared names by default (see Naming, XmlName); enums are their case names in the
/// same naming. Any other field type stops the build with an error naming the field; [XmlIgnore]
/// leaves a field out.
///
/// Reading fills an existing object: a missing attribute, element or text leaves its field as it was
/// (unless [XmlRequired]). Unknown attributes and elements are ignored, unless the type is Strict. A
/// String, object or List field that is null when read gets a new instance, which the object then
/// owns (declare such fields with `~ delete _` or a container delete). Writing updates the element in
/// place: values set, children written into the existing ones, so a document read with PreserveStyle
/// keeps its formatting; a value that did not change is not touched.
[AttributeUsage(.Class | .Struct)]
public struct XmlObjectAttribute : Attribute, IComptimeTypeApply
{
	/// @brief How field, type and enum case names become XML names ([XmlName] on a field overrides).
	public XmlNaming Naming;

	/// @brief The type's element name (local), where one is needed: list items, [XmlChildren], a
	/// document's root element. Unset, the type's name through Naming.
	public String Name;

	/// @brief The namespace of the type's element and of the child elements its fields map (unset: any
	/// namespace matches when reading, and new elements take the namespace in scope). Attributes are in
	/// no namespace unless their field's [XmlName] gives one.
	public String Namespace;

	/// @brief Reading fails (located) at an attribute, child element or non-whitespace text that no
	/// field maps. Namespace declarations and `xml:` attributes are always allowed.
	public bool Strict;

	/// @brief Also emit the generated code as text, `static StringView XmlGeneratedSource`, to read or
	/// print when debugging a mapping (the IDE shows emitted code too; the command line does not).
	public bool ShowGenerated;

	/// @brief Checks the type's fields and emits IXmlSerializable into it.
	/// @param type The type carrying the attribute.
	[Comptime]
	public void ApplyToType(Type type)
	{
		XmlSerializerCodeGen.Emit(type, Naming, (Name != null) ? Name : "", (Namespace != null) ? Namespace : "", Strict, ShowGenerated);
	}
}

/// @brief How [XmlObject] turns declared names into XML names. Words split at case changes, keeping
/// acronyms together: `HTTPPort` is `http-port` in KebabCase.
public enum XmlNaming
{
	/// @brief The name as written: `strokeWidth`, `PoolSize` (the default, as XML formats differ).
	AsDeclared,
	/// @brief `poolSize`.
	CamelCase,
	/// @brief `pool-size`.
	KebabCase,
	/// @brief `pool_size`.
	SnakeCase,
	/// @brief `poolsize`.
	Lower
}

/// @brief Maps a field to `name` instead of its own name, optionally in a namespace.
[AttributeUsage(.Field)]
public struct XmlNameAttribute : Attribute
{
	/// @brief The XML local name.
	public String mName;
	/// @brief The namespace (unset: for an element, the type's Namespace; for an attribute, none).
	public String Namespace;

	/// @brief Use `name` for the field.
	/// @param name The attribute or element local name.
	public this(String name)
	{
		mName = name;
		Namespace = null;
	}
}

/// @brief An older name, so documents written before a rename still read. Repeatable. Reading tries the
/// current name first, then each alias; writing uses the current name and renames what it finds under
/// an alias.
[AttributeUsage(.Field)]
public struct XmlAliasAttribute : Attribute
{
	/// @brief The older name.
	public String mName;

	/// @brief Also accept `name`.
	/// @param name The older local name.
	public this(String name)
	{
		mName = name;
	}
}

/// @brief Leaves a field out of the generated reading and writing.
[AttributeUsage(.Field)]
public struct XmlIgnoreAttribute : Attribute
{
}

/// @brief Makes reading fail (located at the element) when the field's attribute, element or text is
/// absent.
[AttributeUsage(.Field)]
public struct XmlRequiredAttribute : Attribute
{
}

/// @brief Maps a scalar to an attribute (the default for scalars), or a List of scalars to one attribute
/// holding the items separated by spaces.
[AttributeUsage(.Field)]
public struct XmlAttributeAttribute : Attribute
{
}

/// @brief Maps a scalar field to a child element holding the value as its text: `<title>x</title>`.
[AttributeUsage(.Field)]
public struct XmlElementAttribute : Attribute
{
}

/// @brief Maps a scalar field to the element's own text (its Text and CDATA children). One per type.
[AttributeUsage(.Field)]
public struct XmlTextAttribute : Attribute
{
}

/// @brief Puts a List field's items inside a wrapper element: `<tags><tag>a</tag></tags>`.
[AttributeUsage(.Field)]
public struct XmlArrayAttribute : Attribute
{
	/// @brief The wrapper's local name (unset: the field's name).
	public String Name;
	/// @brief The items' local name (unset: for objects, the item type's element name; for scalars,
	/// `item`).
	public String Item;
}

/// @brief The XML shape of a Dictionary field (see XmlMap).
public enum XmlMapStyle
{
	/// @brief One element per key named after the value's type, the key in an attribute:
	/// `<int32 name="retries">3</int32>` (the default). Explicit about types; an [XmlObject] value is
	/// the entry element itself, and a dictionary of a base class reads each entry as the subtype its
	/// element name says. Key: the key attribute (`name`); Entry: the element name for scalar values
	/// (the value type's name: `string`, `bool`, `int32`, `double`, an enum's name through the naming).
	TypedEntries,
	/// @brief One element per key with a fixed name, the key in an attribute: `<entry key="a">1</entry>`;
	/// with Value, the value in an attribute too: `<add key="a" value="1"/>` (.NET appSettings). Entry
	/// (`entry`), Key (`key`), Value (unset: the text).
	Entries,
	/// @brief One element per key holding a key element and a value element:
	/// `<entry><key>a</key><value>1</value></entry>` (JAXB's form); any key, any value. Entry (`entry`),
	/// Key (`key`), Value (`value`).
	KeyValueElements,
	/// @brief One element per key, named by the key: `<timeout>30</timeout>`. Compact for configuration,
	/// but only keys that are XML names can be written (an error otherwise).
	KeysAsNames,
	/// @brief The keys are attribute names, the values their values: `<limits a="1" b="2"/>`. Scalar
	/// values only.
	Attributes
}

/// @brief How a Dictionary<K, V> field is mapped (K a String, integer or enum; V a scalar or [XmlObject]
/// type). Without it: TypedEntries in a wrapper element named after the field:
/// `<limits><int32 name="retries">3</int32></limits>`.
///
/// Unwrapped (`Wrapped = false`) the entries are in the element itself; KeysAsNames then takes every
/// child element and Attributes every attribute that no other field maps, a catch-all for what a type
/// does not model. Reading checks names (a TypedEntries entry of another type is an error) and lets the
/// last of repeated keys win; writing updates the entries in place by key, appends new keys, and
/// removes keys the dictionary no longer has (a null value removes its entry).
[AttributeUsage(.Field)]
public struct XmlMapAttribute : Attribute
{
	/// @brief The shape.
	public XmlMapStyle Style;
	/// @brief The key's attribute or element name (the style's default when unset).
	public String Key;
	/// @brief The entries' element name (the style's default when unset).
	public String Entry;
	/// @brief Entries: the value's attribute name (unset: the value is the text); KeyValueElements: the
	/// value element's name.
	public String Value;
	/// @brief Whether the entries are inside a wrapper element named after the field (the default).
	public bool Wrapped = true;
}

/// @brief Maps a List<T> field to every child element that no other field claims; each child is read as
/// the [XmlObject] type assignable to T whose element name it has.
[AttributeUsage(.Field)]
public struct XmlChildrenAttribute : Attribute
{
}

/// @brief A type that reads itself from and writes itself to an element. [XmlObject] generates it; a
/// type can also implement it by hand.
public interface IXmlSerializable
{
	/// @brief The local name of this object's element (for list items, [XmlChildren], a root element).
	StringView XmlElementName { get; }

	/// @brief The namespace of this object's element, empty for none or any.
	StringView XmlElementNamespace { get; }

	/// @brief Fill this object's fields from `element`.
	/// @param element The element to read.
	/// @param allocator Where the objects the read creates (Strings, nested objects, Lists) come from,
	/// for example a `scope BumpAllocator`; null for the heap, and then this object owns them.
	/// @return .Ok, or the first error, located in the source when the document has positions.
	Result<void, XmlParseError> XmlRead(XmlNode element, ITypedAllocator allocator = null) mut;

	/// @brief Write this object's fields into `element`, updating what is there (so a document read
	/// with PreserveStyle keeps its formatting).
	/// @param element The element to write.
	/// @return .Ok, or an error.
	Result<void, XmlParseError> XmlWrite(XmlNode element);
}

/// @brief Reads and writes one type `T` held in a single XML value (an attribute value, an element's
/// text, a list token) for [XmlObject] fields: types the serializer does not know, or a custom form
/// such as `12px` for a Length. Register it for every field of type T with [XmlConverter(typeof(T))]
/// on the converter, or use it for one field with [XmlUseConverter(typeof(Converter))].
///
/// ```
/// [XmlConverter(typeof(Color))]
/// struct ColorXml : IXmlConverter<Color>
/// {
/// 	public static Result<void, XmlParseError> Read(XmlValueRef value, ref Color target)
/// 	{
/// 		if (!Color.TryParse(value.mText, out target))
/// 			return .Err(value.MakeError("expected a color such as #ff0000"));
/// 		return .Ok;
/// 	}
///
/// 	public static bool Write(Color value, String output)
/// 	{
/// 		value.ToHex(output);
/// 		return true;
/// 	}
/// }
/// ```
public interface IXmlConverter<T>
{
	/// @brief Read `value` into `target`.
	/// @param value The text and where it is (for errors).
	/// @param target The field or new list item to fill.
	/// @return .Ok, or an error (usually from value.MakeError).
	static Result<void, XmlParseError> Read(XmlValueRef value, ref T target);

	/// @brief Write `value` as text.
	/// @param value The value to write.
	/// @param output Receives the text.
	/// @return False to leave the value out (the attribute or element removed), as a null String is.
	static bool Write(T value, String output);
}

/// @brief Registers the converter it is placed on (an IXmlConverter<T>) for every [XmlObject] field and
/// list item of type `T`, in every project that can see the converter. At most one converter per type.
[AttributeUsage(.Struct | .Class)]
public struct XmlConverterAttribute : Attribute
{
	/// @brief The type the converter handles.
	public Type mTarget;

	/// @brief Register the converter for `target`.
	/// @param target The type the converter handles.
	public this(Type target)
	{
		mTarget = target;
	}
}

/// @brief Reads and writes one field with the given converter (an IXmlConverter<T> for the field's type,
/// or its item type for a List), ahead of any registered converter or built-in handling.
[AttributeUsage(.Field)]
public struct XmlUseConverterAttribute : Attribute
{
	/// @brief The converter type.
	public Type mConverter;

	/// @brief Use `converter` for this field.
	/// @param converter The converter type.
	public this(Type converter)
	{
		mConverter = converter;
	}
}
