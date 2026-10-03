using System;
using System.Collections;
using XmlBeef;

namespace Fixtures;

// Each fixture is built alone by test-codegen.sh, with -define=FIXTURE_<name>. A line
// `// FIXTURE <name>: <text>` gives the text the build error must contain, or OK for a mapping that must
// build (a positive control: the checks must not reject it).

class Program
{
	public static int Main()
	{
		return 0;
	}
}

// FIXTURE OkBaseline: OK
#if FIXTURE_OkBaseline
[XmlObject(Name = "item")]
class Item
{
	public int32 id;
	[XmlElement] public String title;
	public List<int32> counts;
	[XmlMap] public Dictionary<String, int32> totals;
}
#endif

struct Temperature
{
	public double mCelsius;
}

// FIXTURE OkRegisteredConverter: OK
#if FIXTURE_OkRegisteredConverter
// Registered in this project while another project (Other) also depends on XmlBeef: found by the
// mixin-stage lookup (before, through AlwaysVisible, it was not, and the field was not supported)
[XmlConverter(typeof(Temperature))]
struct TemperatureXml : IXmlConverter<Temperature>
{
	public static Result<void, XmlParseError> Read(XmlValueRef value, ref Temperature target)
	{
		if (!(double.Parse(value.mText) case .Ok(let celsius)))
			return .Err(value.MakeError("expected a temperature"));
		target.mCelsius = celsius;
		return .Ok;
	}

	public static bool Write(Temperature value, String output)
	{
		XmlBind.AppendDouble(output, value.mCelsius);
		return true;
	}
}

[XmlObject]
class Station
{
	public Temperature outside;
	public List<Temperature> history ~ delete _;
}
#endif

// FIXTURE OkSelfReference: OK
#if FIXTURE_OkSelfReference
// A type that holds itself: planned when its methods compile, so no type-initialization cycle
[XmlObject(Name = "node")]
class TreeNode
{
	public String label ~ delete _;
	public List<TreeNode> children ~ DeleteContainerAndItems!(_);
}
#endif

// FIXTURE OkSameNameInTwoNamespaces: OK
#if FIXTURE_OkSameNameInTwoNamespaces
[XmlObject(Name = "doc")]
class Doc
{
	[XmlElement, XmlName("title", Namespace = "urn:a")] public String first;
	[XmlElement, XmlName("title", Namespace = "urn:b")] public String second;
}
#endif

// FIXTURE ArrayNeedsList: [XmlArray] needs a List of scalars or of [XmlObject] types
#if FIXTURE_ArrayNeedsList
[XmlObject]
class Bad
{
	[XmlArray] public int32 count;
}
#endif

// FIXTURE ArrayAndAttribute: [XmlArray] and [XmlAttribute] are different places
#if FIXTURE_ArrayAndAttribute
[XmlObject]
class Bad
{
	[XmlArray, XmlAttribute] public List<int32> counts;
}
#endif

// FIXTURE ChildrenNeedsList: [XmlChildren] needs a List<T> field
#if FIXTURE_ChildrenNeedsList
[XmlObject]
class Bad
{
	[XmlChildren] public int32 count;
}
#endif

// FIXTURE TextNeedsScalar: [XmlText] needs a scalar field
#if FIXTURE_TextNeedsScalar
[XmlObject]
class Bad
{
	[XmlText] public List<int32> counts;
}
#endif

// FIXTURE UnsupportedType: XML serialization does not support fields of type char8
#if FIXTURE_UnsupportedType
[XmlObject]
class Bad
{
	public char8 letter;
}
#endif

// FIXTURE TwoRoles: has more than one of [XmlAttribute], [XmlElement], [XmlText] and [XmlChildren]
#if FIXTURE_TwoRoles
[XmlObject]
class Bad
{
	[XmlAttribute, XmlElement] public int32 count;
}
#endif

// FIXTURE TwoTexts: the text is mapped by both Fixtures.Bad.a and Fixtures.Bad.b
#if FIXTURE_TwoTexts
[XmlObject]
class Bad
{
	[XmlText] public String a;
	[XmlText] public String b;
}
#endif

// FIXTURE DuplicateAttribute: the attribute `x` is mapped by both Fixtures.Bad.a and Fixtures.Bad.b
#if FIXTURE_DuplicateAttribute
[XmlObject]
class Bad
{
	[XmlName("x")] public int32 a;
	[XmlName("x")] public int32 b;
}
#endif

// FIXTURE AliasCollision: the element `old` is mapped by both
#if FIXTURE_AliasCollision
[XmlObject]
class Bad
{
	[XmlElement, XmlAlias("old")] public String a;
	[XmlElement, XmlName("old")] public String b;
}
#endif

// FIXTURE OverlappingNamespaces: the elements `a` (Fixtures.Bad.any) and `{urn:specific}a` (Fixtures.Bad.specific) overlap
#if FIXTURE_OverlappingNamespaces
[XmlObject]
class Bad
{
	[XmlElement, XmlName("a")] public String any;
	[XmlElement, XmlName("a", Namespace = "urn:specific")] public String specific;
}
#endif

// FIXTURE InheritedCollision: the attribute `id` is mapped by both Fixtures.Bad.other and Fixtures.Base.id
#if FIXTURE_InheritedCollision
[XmlObject]
class Base
{
	public int32 id;
}

[XmlObject]
class Bad : Base
{
	[XmlName("id")] public int32 other;
}
#endif

// FIXTURE InvalidName: `a:b` is not a valid XML local name
#if FIXTURE_InvalidName
[XmlObject]
class Bad
{
	[XmlName("a:b")] public int32 count;
}
#endif

// FIXTURE TwoCatchAlls: would both take every child element no other field maps
#if FIXTURE_TwoCatchAlls
[XmlObject]
class Child
{
	public int32 id;
}

[XmlObject]
class Bad
{
	[XmlChildren] public List<Child> children;
	[XmlMap(Style = .KeysAsNames, Wrapped = false)] public Dictionary<String, String> rest;
}
#endif

// FIXTURE MapKeyType: dictionary keys must be String, integers or enums, not float
#if FIXTURE_MapKeyType
[XmlObject]
class Bad
{
	public Dictionary<float, int32> values;
}
#endif

// FIXTURE MapAttributesOfObjects: an Attributes dictionary needs scalar values
#if FIXTURE_MapAttributesOfObjects
[XmlObject]
class Value
{
	public int32 id;
}

[XmlObject]
class Bad
{
	[XmlMap(Style = .Attributes)] public Dictionary<String, Value> values;
}
#endif

// FIXTURE MapKeyCollision: the key attribute `name` is also an attribute of Fixtures.Value
#if FIXTURE_MapKeyCollision
[XmlObject]
struct Value
{
	public String name;
}

[XmlObject]
class Bad
{
	public Dictionary<String, Value> values;
}
#endif

// FIXTURE TwoConverters: [XmlConverter] Both
#if FIXTURE_TwoConverters
struct Length
{
	public double mValue;
}

[XmlConverter(typeof(Length))]
struct LengthA : IXmlConverter<Length>
{
	public static Result<void, XmlParseError> Read(XmlValueRef value, ref Length target) => .Ok;
	public static bool Write(Length value, String output) => true;
}

[XmlConverter(typeof(Length))]
struct LengthB : IXmlConverter<Length>
{
	public static Result<void, XmlParseError> Read(XmlValueRef value, ref Length target) => .Ok;
	public static bool Write(Length value, String output) => true;
}

[XmlObject]
class Bad
{
	public Length width;
}
#endif
