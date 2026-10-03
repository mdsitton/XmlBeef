using System;
using System.Collections;
using System.Reflection;
using FormatCore.Mapping;
using internal FormatCore;

namespace XmlBeef;

/// The planning half of the generator (review A03): what each field is (its kinds and role), the names
/// it claims and the conflicts between them, all checked before XmlSerializerCodeGen.bf writes any
/// code from the plans. Naming and type helpers that both halves use are here too.
extension XmlSerializerCodeGen
{
	enum Kind
	{
		Unsupported,
		Bool,
		Integer,
		Float,
		String,
		Enum,
		Object,
		List,
		/// Dictionary<K, V>
		Dictionary,
		/// An IXmlConverter<T>: from [XmlUseConverter] on the field, or registered with [XmlConverter]
		Converter
	}

	/// Where a field lives in an element.
	enum Role
	{
		/// A scalar: an attribute.
		Attribute,
		/// A scalar: a child element's text ([XmlElement]).
		Element,
		/// A scalar: the element's own text ([XmlText]).
		Text,
		/// A List of scalars: one attribute, the items separated by spaces ([XmlAttribute]).
		AttributeList,
		/// A List of scalars: repeated child elements, each holding an item as its text.
		ElementList,
		/// An [XmlObject]: a child element.
		ChildObject,
		/// A List of [XmlObject]s: repeated child elements.
		ChildObjects,
		/// A List<T>: every unclaimed child element, read as the [XmlObject] type named after it
		/// ([XmlChildren]).
		Children,
		/// A Dictionary, in the shape its [XmlMap] gives (XmlMapStyle).
		Map
	}

	/// How one field maps: what Emit writes code from. For a List field, mElement* describe its items.
	class FieldPlan
	{
		public FieldInfo mField;
		/// The XML name, its namespace and aliases, as Beef string literals. For a list: the items' name
		/// (mName) and the wrapper's (mWrapper, empty when unwrapped).
		public String mName = new .() ~ delete _;
		public String mNamespace = new .() ~ delete _;
		public List<String> mAliases = new .() ~ DeleteContainerAndItems!(_);
		public String mWrapper = new .() ~ delete _;
		/// The wrapper's namespace (a literal): the field's, as for any child element of the type; the
		/// items may be in their own type's.
		public String mWrapperNamespace = new .() ~ delete _;
		public bool mRequired;
		public Role mRole;
		public Type mType;
		public Kind mKind;
		public Type mConverter;
		public Type mElement;
		public Kind mElementKind;
		public Type mElementConverter;
		/// A Dictionary: mElement* describe its values, these its keys and shape (names as literals;
		/// mEntryType: TypedEntries' element name for scalar or struct values).
		public Type mKeyType;
		public Kind mKeyKind;
		public XmlMapStyle mMapStyle;
		public bool mWrapped;
		public String mMapEntry = new .() ~ delete _;
		public String mMapKey = new .() ~ delete _;
		public String mMapValue = new .() ~ delete _;
		public String mEntryType = new .() ~ delete _;

		public this()
		{
		}
	}

	/// The field's XML name: [XmlName], or its name through the naming.
	[Comptime]
	static void FieldName(FieldInfo field, XmlNaming naming, String name)
	{
		if (field.GetCustomAttribute<XmlNameAttribute>() case .Ok(let named))
			name.Append(named.mName);
		else
			ApplyNaming(field.Name, naming, name);
	}

	/// The namespace of the field's attribute (none unless [XmlName] gives one) or elements (the type's
	/// unless [XmlName] gives one).
	[Comptime]
	static void FieldNamespace(FieldInfo field, bool attribute, StringView typeNamespace, String ns)
	{
		if (field.GetCustomAttribute<XmlNameAttribute>() case .Ok(let named) && named.Namespace != null)
			ns.Append(named.Namespace);
		else if (!attribute)
			ns.Append(typeNamespace);
	}

	/// Classifies a field of the type being generated and picks its role, stopping the build (naming the
	/// field) for a type or role attribute that cannot work.
	[Comptime]
	static FieldPlan PlanField(FieldInfo field, XmlNaming naming, StringView typeNamespace, StringView ownerName)
	{
		let plan = new FieldPlan();
		plan.mField = field;
		let xmlName = FieldName(field, naming, .. scope .());
		CheckName(ownerName, field.Name, xmlName);
		for (let alias in field.GetCustomAttributes<XmlAliasAttribute>())
		{
			CheckName(ownerName, field.Name, alias.mName);
			plan.mAliases.Add(AppendLiteral(.. new .(), alias.mName));
		}
		plan.mRequired = field.HasCustomAttribute<XmlRequiredAttribute>();

		let fieldType = field.FieldType;
		plan.mType = fieldType;
		Type useConverter = null;
		if (field.GetCustomAttribute<XmlUseConverterAttribute>() case .Ok(let use))
			useConverter = use.mConverter;
		let kind = LeafKind(fieldType, useConverter, let converter);
		plan.mKind = kind;
		plan.mConverter = converter;
		Type element = null;
		var elementKind = Kind.Unsupported;
		Type elementConverter = null;
		if (kind == .List)
		{
			element = ListElement(fieldType);
			elementKind = LeafKind(element, useConverter, out elementConverter);
		}
		plan.mElement = element;
		plan.mElementKind = elementKind;
		plan.mElementConverter = elementConverter;

		bool scalar = IsScalar(kind);
		bool scalarList = kind == .List && IsScalar(elementKind);
		bool objectList = kind == .List && elementKind == .Object;
		bool isAttribute = field.HasCustomAttribute<XmlAttributeAttribute>();
		bool wrapped = field.GetCustomAttribute<XmlArrayAttribute>() case .Ok(let array);
		if (wrapped && !scalarList && !objectList)
			Fail(ownerName, field.Name, "[XmlArray] needs a List of scalars or of [XmlObject] types");
		if (wrapped && isAttribute)
			Fail(ownerName, field.Name, "[XmlArray] and [XmlAttribute] are different places: a wrapper element, or one attribute");

		if (field.HasCustomAttribute<XmlChildrenAttribute>())
		{
			if (kind != .List)
				Fail(ownerName, field.Name, "[XmlChildren] needs a List<T> field");
			plan.mRole = .Children;
		}
		else if (field.HasCustomAttribute<XmlTextAttribute>())
		{
			if (!scalar)
				Fail(ownerName, field.Name, "[XmlText] needs a scalar field (bool, integers, floats, String, enums, converter types)");
			plan.mRole = .Text;
		}
		else if (field.HasCustomAttribute<XmlElementAttribute>())
		{
			if (!scalar)
				Fail(ownerName, field.Name, "[XmlElement] needs a scalar field; [XmlObject] and List fields are child elements already");
			plan.mRole = .Element;
		}
		else if (isAttribute && scalarList)
			plan.mRole = .AttributeList;
		else if (isAttribute && !scalar)
			Fail(ownerName, field.Name, "[XmlAttribute] needs a scalar field or a List of scalars");
		else if (scalar)
			plan.mRole = .Attribute;
		else if (kind == .Object)
			plan.mRole = .ChildObject;
		else if (scalarList)
			plan.mRole = .ElementList;
		else if (objectList)
			plan.mRole = .ChildObjects;
		else if (kind == .Dictionary)
			PlanMap(plan, field, useConverter, typeNamespace, ownerName);
		else
		{
			let typeName = fieldType.GetFullName(.. scope .());
			Fail(ownerName, field.Name, scope $"XML serialization does not support fields of type {typeName}. Supported: bool, integers, float, double, String, enums, [XmlObject] types, Lists of those, and Dictionaries with String, integer or enum keys and values of those; also types with a converter ([XmlConverter] registration or [XmlUseConverter] on the field). Mark the field [XmlIgnore] to leave it out.");
			plan.mRole = .Attribute;
		}

		// Names: a list's items, inside its wrapper when it has one
		let ns = FieldNamespace(field, plan.mRole == .Attribute || plan.mRole == .AttributeList, typeNamespace, .. scope .());
		if (plan.mRole == .ElementList || plan.mRole == .ChildObjects)
		{
			let item = scope String();
			if (wrapped && array.Item != null)
				item.Append(array.Item);
			else if (plan.mRole == .ElementList)
				item.Append(wrapped ? "item" : xmlName);
			else if (!wrapped && field.HasCustomAttribute<XmlNameAttribute>())
				item.Append(xmlName);
			else
				ElementName(element, item);
			CheckName(ownerName, field.Name, item);
			AppendLiteral(plan.mName, item);
			if (wrapped)
			{
				let wrapper = (array.Name != null) ? array.Name : xmlName;
				CheckName(ownerName, field.Name, wrapper);
				AppendLiteral(plan.mWrapper, wrapper);
				AppendLiteral(plan.mWrapperNamespace, ns);
			}
			// Items of [XmlObject] types are in their own namespace when they have one
			let itemNs = scope String(ns);
			if (plan.mRole == .ChildObjects && !field.HasCustomAttribute<XmlNameAttribute>())
			{
				let own = TypeNamespace(element, .. scope .());
				if (!own.IsEmpty)
					itemNs.Set(own);
			}
			AppendLiteral(plan.mNamespace, itemNs);
		}
		else
		{
			AppendLiteral(plan.mName, xmlName);
			AppendLiteral(plan.mNamespace, ns);
		}
		return plan;
	}

	/// A Dictionary field's plan: its key and value kinds and its shape ([XmlMap]), checked.
	[Comptime]
	static void PlanMap(FieldPlan plan, FieldInfo field, Type useConverter, StringView typeNamespace, StringView ownerName)
	{
		plan.mRole = .Map;
		let fieldType = field.FieldType;
		let keyType = DictionaryKey(fieldType);
		let valueType = DictionaryValue(fieldType);
		plan.mKeyType = keyType;
		plan.mKeyKind = KeyKind(keyType);
		if (plan.mKeyKind == .Unsupported)
			Fail(ownerName, field.Name, scope $"dictionary keys must be String, integers or enums, not {keyType.GetFullName(.. scope .())}");
		plan.mElement = valueType;
		plan.mElementKind = LeafKind(valueType, useConverter, out plan.mElementConverter);
		bool objectValue = plan.mElementKind == .Object;
		if (!IsScalar(plan.mElementKind) && !objectValue)
			Fail(ownerName, field.Name, scope $"dictionary values must be scalars or [XmlObject] types, not {valueType.GetFullName(.. scope .())}");

		let map = MapOf(field);
		plan.mMapStyle = map.Style;
		plan.mWrapped = map.Wrapped;
		StringView key = default;
		StringView entry = default;
		StringView value = default;
		switch (map.Style)
		{
		case .TypedEntries:
			key = "name";
		case .Entries:
			key = "key";
			entry = "entry";
		case .KeyValueElements:
			key = "key";
			entry = "entry";
			value = "value";
		case .KeysAsNames, .Attributes:
		}
		if (map.Key != null)
			key = map.Key;
		if (map.Entry != null)
			entry = map.Entry;
		if (map.Value != null)
			value = map.Value;
		for (let name in StringView[3](key, entry, value))
		{
			if (!name.IsEmpty)
				CheckName(ownerName, field.Name, name);
		}
		AppendLiteral(plan.mMapKey, key);
		AppendLiteral(plan.mMapValue, value);

		XmlNaming naming = CaseNaming(plan);
		switch (map.Style)
		{
		case .TypedEntries:
			// Scalars and structs: one element name; classes: their subtypes' names, dispatched on reading
			let typeName = scope String();
			if (map.Entry != null)
				typeName.Append(map.Entry);
			else if (objectValue)
				ElementName(valueType, typeName);
			else
				ScalarTypeName(valueType, plan.mElementKind, naming, typeName);
			AppendLiteral(plan.mEntryType, typeName);
			// Wrapped, every element is an entry (one of another type is an error); unwrapped, the
			// entries are told from the element's other children by name
			AppendLiteral(plan.mMapEntry, map.Wrapped ? "" : typeName);
			if (!map.Wrapped && objectValue && !valueType.IsValueType)
				Fail(ownerName, field.Name, "an unwrapped TypedEntries dictionary needs scalar or struct values (a class's subtypes have element names of their own)");
		case .Attributes:
			if (objectValue)
				Fail(ownerName, field.Name, "an Attributes dictionary needs scalar values: an object cannot be an attribute");
			AppendLiteral(plan.mMapEntry, "");
		default:
			AppendLiteral(plan.mMapEntry, entry);
		}
		if (map.Style == .Entries && !value.IsEmpty && objectValue)
			Fail(ownerName, field.Name, "[XmlMap] Value puts each value in an attribute: the values must be scalars");
		if (objectValue && !valueType.IsValueType && valueType.IsAbstract && map.Style != .TypedEntries)
			Fail(ownerName, field.Name, "a dictionary of an abstract type needs TypedEntries (the entry's element name says its type)");
		// The key attribute is on the object's own element
		if (objectValue && (map.Style == .TypedEntries || map.Style == .Entries) && ClaimsAttribute(valueType, key))
			Fail(ownerName, field.Name, scope $"the key attribute `{key}` is also an attribute of {valueType.GetFullName(.. scope .())}: give the key another name ([XmlMap(Key = ...)])");
	}

	/// Over the whole [XmlObject] chain from `type` (a base's fields are read by its own XmlRead, called
	/// first, but they share the element): the child element and attribute names the fields claim (Beef
	/// literals, comma-separated), which an [XmlChildren] list and the strict check leave alone; whether an
	/// [XmlChildren] list takes the rest, and whether a field maps the text. Stops the build for mappings
	/// that would read the same XML twice: several role attributes on a field, a second [XmlText] or
	/// [XmlChildren], and two attributes or two child elements with one name.
	[Comptime]
	static void ScanChain(Type type, XmlNaming naming, StringView typeNamespace, StringView ownerName, String claimedElements, out int elementCount, String claimedAttributes, out int attributeCount, out bool allElements, out bool allAttributes, out bool mapsText)
	{
		elementCount = 0;
		attributeCount = 0;
		allElements = false;
		allAttributes = false;
		mapsText = false;
		String textField = null;
		String childrenField = null;
		String attributesField = null;
		// The field that maps each attribute and element name ("Type.Field")
		let attributes = scope Dictionary<String, String>();
		let elements = scope Dictionary<String, String>();
		defer
		{
			delete textField;
			delete childrenField;
			delete attributesField;
			for (let entry in attributes)
			{
				delete entry.key;
				delete entry.value;
			}
			for (let entry in elements)
			{
				delete entry.key;
				delete entry.value;
			}
		}
		for (Type level = type; level != null && level.HasCustomAttribute<XmlObjectAttribute>(); level = level.IsValueType ? null : level.BaseType)
		{
			var levelNaming = naming;
			if (level != type && level.GetCustomAttribute<XmlObjectAttribute>() case .Ok(let attribute))
				levelNaming = attribute.Naming;
			for (let field in level.GetFields())
			{
				if (!IsSerialized(level, field))
					continue;
				let fieldPath = scope $"{level.GetFullName(.. scope .())}.{field.Name}";
				int roles = (field.HasCustomAttribute<XmlAttributeAttribute>() ? 1 : 0) + (field.HasCustomAttribute<XmlElementAttribute>() ? 1 : 0) +
					(field.HasCustomAttribute<XmlTextAttribute>() ? 1 : 0) + (field.HasCustomAttribute<XmlChildrenAttribute>() ? 1 : 0);
				if (roles > 1)
					FailType(ownerName, scope $"{fieldPath} has more than one of [XmlAttribute], [XmlElement], [XmlText] and [XmlChildren]: a field has one place in an element");

				if (field.HasCustomAttribute<XmlTextAttribute>())
				{
					if (textField != null)
						FailType(ownerName, scope $"the text is mapped by both {textField} and {fieldPath} ([XmlText])");
					textField = new .(fieldPath);
					mapsText = true;
					continue;
				}
				// Catch-alls: [XmlChildren], and the unwrapped KeysAsNames (elements) and Attributes dictionaries
				let map = MapOf(field);
				bool unwrappedMap = DictionaryValue(field.FieldType) != null && !map.Wrapped;
				if (field.HasCustomAttribute<XmlChildrenAttribute>() || (unwrappedMap && map.Style == .KeysAsNames))
				{
					if (childrenField != null)
						FailType(ownerName, scope $"{childrenField} and {fieldPath} would both take every child element no other field maps ([XmlChildren], an unwrapped KeysAsNames dictionary): only one is allowed in a type and its [XmlObject] bases");
					childrenField = new .(fieldPath);
					allElements = true;
					continue;
				}
				if (unwrappedMap && map.Style == .Attributes)
				{
					if (attributesField != null)
						FailType(ownerName, scope $"{attributesField} and {fieldPath} would both take every attribute no other field maps (unwrapped Attributes dictionaries): only one is allowed in a type and its [XmlObject] bases");
					attributesField = new .(fieldPath);
					allAttributes = true;
					continue;
				}
				let names = scope List<String>();
				defer { ClearAndDeleteItems!(names); }
				let levelNamespace = TypeNamespace(level, .. scope .());
				bool isAttribute = ClaimedNames(field, levelNaming, levelNamespace, names);
				if (unwrappedMap)
				{
					// The entries' element name, in the field's namespace
					ClearAndDeleteItems!(names);
					let fieldType = field.FieldType;
					let valueType = DictionaryValue(fieldType);
					let valueKind = LeafKind(valueType, null, ?);
					let entry = new String();
					if (map.Entry != null)
						entry.Append(map.Entry);
					else if (map.Style != .TypedEntries)
						entry.Append("entry");
					else if (valueKind == .Object)
						ElementName(valueType, entry);
					else
						ScalarTypeName(valueType, valueKind, levelNaming, entry);
					names.Add(Claim(FieldNamespace(field, false, levelNamespace, .. scope .()), entry, .. new .()));
					delete entry;
				}
				let used = isAttribute ? attributes : elements;
				for (let claim in names)
				{
					if (used.TryGetValue(claim, let other))
						FailType(ownerName, scope $"{isAttribute ? "the attribute" : "the element"} `{claim}` is mapped by both {other} and {fieldPath} (the name comes from [XmlName] or the field's name, or for a List of objects from the item type's element name)");
					// An element name without a namespace matches that name in every namespace
					if (!isAttribute)
					{
						for (let entry in elements)
						{
							if (entry.value != fieldPath && ElementClaimsOverlap(entry.key, claim))
								FailType(ownerName, scope $"the elements `{entry.key}` ({entry.value}) and `{claim}` ({fieldPath}) overlap: a name without a namespace matches that name in every namespace, so both fields would read the same element. Give both a namespace, or different names");
						}
					}
					used[new .(claim)] = new .(fieldPath);
					if (isAttribute)
					{
						if (attributeCount++ > 0)
							claimedAttributes.Append(", ");
						AppendLiteral(claimedAttributes, claim);
					}
					else
					{
						if (elementCount++ > 0)
							claimedElements.Append(", ");
						AppendLiteral(claimedElements, claim);
					}
				}
			}
		}
	}

	[Comptime]
	static bool IsSerialized(Type type, FieldInfo field)
	{
		return field.DeclaringType == type && !field.IsStatic && !field.IsConst && field.IsPublic && !field.HasCustomAttribute<XmlIgnoreAttribute>();
	}

	[Comptime]
	static void Fail(StringView ownerName, StringView fieldName, StringView message)
	{
		Runtime.FatalError(scope $"[XmlObject] {ownerName}.{fieldName}: {message}");
	}

	/// A mapping error about the type as a whole: `message` names the fields (with their declaring types).
	[Comptime]
	static void FailType(StringView ownerName, StringView message)
	{
		Runtime.FatalError(scope $"[XmlObject] {ownerName}: {message}");
	}

	/// Stops the build for a name that cannot be an XML local name (empty, a colon, a character no name
	/// may start with or contain, as far as ASCII goes).
	[Comptime]
	static void CheckName(StringView ownerName, StringView fieldName, StringView name)
	{
		bool ok = !name.IsEmpty;
		for (int i < name.Length)
		{
			char8 c = name[i];
			if ((uint8)c >= 0x80 || c.IsLetter || c == '_')
				continue;
			if (i > 0 && (c.IsDigit || c == '-' || c == '.'))
				continue;
			ok = false;
		}
		if (!ok)
		{
			let place = fieldName.IsEmpty ? scope String(ownerName) : scope $"{ownerName}.{fieldName}";
			Runtime.FatalError(scope $"[XmlObject] {place}:`{name}` is not a valid XML local name (a letter or `_` first, then letters, digits, `-`, `_`, `.`; no colon: give a namespace instead)");
		}
	}

	/// The names a field claims, and whether they are attribute names (else child element names): a
	/// list's wrapper, or its items when unwrapped.
	[Comptime]
	static bool ClaimedNames(FieldInfo field, XmlNaming naming, StringView typeNamespace, List<String> names)
	{
		let fieldType = field.FieldType;
		let name = FieldName(field, naming, .. scope .());
		Type useConverter = null;
		if (field.GetCustomAttribute<XmlUseConverterAttribute>() case .Ok(let use))
			useConverter = use.mConverter;
		let kind = LeafKind(fieldType, useConverter, ?);
		bool isAttribute = field.HasCustomAttribute<XmlAttributeAttribute>() || (IsScalar(kind) && !field.HasCustomAttribute<XmlElementAttribute>());
		// The namespace as PlanField gives it (an object list's items: their type's, when it has one)
		let ns = FieldNamespace(field, isAttribute, typeNamespace, .. scope .());
		let element = ListElement(fieldType);
		if (element != null && !field.HasCustomAttribute<XmlArrayAttribute>() && !isAttribute && !field.HasCustomAttribute<XmlNameAttribute>() &&
			LeafKind(element, useConverter, ?) == .Object)
		{
			let own = TypeNamespace(element, .. scope .());
			names.Add(Claim(own.IsEmpty ? ns : own, ElementName(element, .. scope .()), .. new .()));
		}
		else if (field.GetCustomAttribute<XmlArrayAttribute>() case .Ok(let array) && array.Name != null)
			names.Add(Claim(ns, array.Name, .. new .()));
		else
			names.Add(Claim(ns, name, .. new .()));
		for (let alias in field.GetCustomAttributes<XmlAliasAttribute>())
			names.Add(Claim(ns, alias.mName, .. new .()));
		return isAttribute;
	}

	/// A claimed name with its namespace: `local`, or `{namespace}local` (James Clark's notation). See
	/// XmlBind.IsClaimedElement and IsClaimedAttribute for what each matches.
	[Comptime]
	static void Claim(StringView ns, StringView local, String claim)
	{
		if (!ns.IsEmpty)
			claim.AppendF("{{{}}}", ns);
		claim.Append(local);
	}

	/// Whether two element claims can match the same element (XmlBind.IsClaimedElement): the same local
	/// name, and the same namespace or no namespace on either (which matches every one).
	[Comptime]
	static bool ElementClaimsOverlap(StringView a, StringView b)
	{
		SplitClaim(a, let nsA, let localA);
		SplitClaim(b, let nsB, let localB);
		return localA == localB && (nsA.IsEmpty || nsB.IsEmpty || nsA == nsB);
	}

	/// A claim's namespace (empty: none) and local name.
	[Comptime]
	static void SplitClaim(StringView claim, out StringView ns, out StringView local)
	{
		ns = default;
		local = claim;
		int close = claim.StartsWith('{') ? claim.IndexOf('}') : -1;
		if (close > 0)
		{
			ns = claim.Substring(1, close - 1);
			local = claim.Substring(close + 1);
		}
	}

	/// How a field or list item of `type` is handled.
	[Comptime]
	static Kind Classify(Type type, out Type converter)
	{
		converter = null;
		if (type == typeof(bool))
			return .Bool;
		if (type == typeof(char8) || type == typeof(char16) || type == typeof(char32))
			return .Unsupported;
		if (type.IsInteger)
			return .Integer;
		if (type == typeof(float) || type == typeof(double))
			return .Float;
		if (type == typeof(String))
			return .String;
		converter = FindRegisteredConverter(type);
		if (converter != null)
			return .Converter;
		// Simple enums only: cases with payloads have no single name to write
		if (type.IsEnum && !type.IsUnion)
			return .Enum;
		if (type.HasCustomAttribute<XmlObjectAttribute>())
			return .Object;
		if (ListElement(type) != null)
			return .List;
		if (DictionaryValue(type) != null)
			return .Dictionary;
		return .Unsupported;
	}

	/// Whether values of `kind` are single XML values.
	[Comptime]
	static bool IsScalar(Kind kind)
	{
		return kind != .Object && kind != .List && kind != .Dictionary && kind != .Unsupported;
	}

	/// The V of a Dictionary<K, V>, or null.
	[Comptime]
	static Type DictionaryValue(Type type) => TypeShapes.DictionaryValue(type);

	/// The K of a Dictionary<K, V>, or null.
	[Comptime]
	static Type DictionaryKey(Type type) => TypeShapes.DictionaryKey(type);

	/// The kind of a dictionary key type, or Unsupported: String, integers (decimal text) and simple enums
	/// (their case names).
	[Comptime]
	static Kind KeyKind(Type type)
	{
		if (type == typeof(String))
			return .String;
		if (type == typeof(char8) || type == typeof(char16) || type == typeof(char32) || type == typeof(bool))
			return .Unsupported;
		if (type.IsInteger)
			return .Integer;
		if (type.IsEnum && !type.IsUnion)
			return .Enum;
		return .Unsupported;
	}

	/// The [XmlMap] of a field, or the defaults.
	[Comptime]
	static XmlMapAttribute MapOf(FieldInfo field)
	{
		if (field.GetCustomAttribute<XmlMapAttribute>() case .Ok(let map))
			return map;
		return XmlMapAttribute();
	}

	/// TypedEntries: the element name of a scalar value type (`string`, `bool`, `int32`, `double`; an
	/// enum's or converter type's name through the naming).
	[Comptime]
	static void ScalarTypeName(Type type, Kind kind, XmlNaming naming, String name)
	{
		if (type == typeof(String))
			name.Append("string");
		else if (kind == .Bool || kind == .Integer || kind == .Float)
			name.Append(type.GetName(.. scope .())..ToLower());
		else
			ApplyNaming(type.GetName(.. scope .()), naming, name);
	}

	/// Whether an [XmlObject] type (with its bases) maps an attribute named `name`.
	[Comptime]
	static bool ClaimsAttribute(Type type, StringView name)
	{
		for (Type level = type; level != null && level.HasCustomAttribute<XmlObjectAttribute>(); level = level.IsValueType ? null : level.BaseType)
		{
			XmlNaming naming = .AsDeclared;
			if (level.GetCustomAttribute<XmlObjectAttribute>() case .Ok(let attribute))
				naming = attribute.Naming;
			for (let field in level.GetFields())
			{
				if (!IsSerialized(level, field))
					continue;
				let names = scope List<String>();
				defer { ClearAndDeleteItems!(names); }
				// (The key attribute is in no namespace: only an unqualified claim is the same name)
				if (!ClaimedNames(field, naming, TypeNamespace(level, .. scope .()), names))
					continue;
				for (let claim in names)
				{
					if (claim == name)
						return true;
				}
			}
		}
		return false;
	}

	/// The kind and converter of a scalar leaf: the [XmlUseConverter] one when given, else as classified.
	[Comptime]
	static Kind LeafKind(Type type, Type useConverter, out Type converter)
	{
		if (useConverter != null && ListElement(type) == null)
		{
			converter = useConverter;
			return .Converter;
		}
		return Classify(type, out converter);
	}

	/// The converter registered with [XmlConverter(typeof(target))] that the type being compiled can see,
	/// or null. Two such registrations stop the build. Only in the mixin stage (XmlSerializerCodeGen.Body):
	/// there "current" is the user's project, and FormatCore's Registry.IsVisible is the user's project
	/// and its dependencies (inside ApplyToType the user's declarations were seen only while the user's
	/// project was XmlBeef's only dependent).
	[Comptime]
	static Type FindRegisteredConverter(Type target)
	{
		Type found = null;
		for (let declaration in Type.TypeDeclarations)
		{
			if (!Registry.IsVisible(declaration))
				continue;
			if (!(declaration.GetCustomAttribute<XmlConverterAttribute>() case .Ok(let registration)) || registration.mTarget != target)
				continue;
			let converter = declaration.ResolvedType;
			if (found != null && found != converter)
				Runtime.FatalError(scope $"[XmlConverter] Both {found.GetFullName(.. scope .())} and {converter.GetFullName(.. scope .())} are registered for {target.GetFullName(.. scope .())}. Keep one, or pick one per field with [XmlUseConverter].");
			found = converter;
		}
		return found;
	}

	/// The [XmlObject] types an [XmlChildren] List<T> can hold: T itself for a struct, else every visible,
	/// concrete class deriving from (or implementing) T. Only in the mixin stage, as FindRegisteredConverter.
	[Comptime]
	static void ChildTypes(Type element, List<Type> types)
	{
		if (element.IsValueType)
		{
			if (element.HasCustomAttribute<XmlObjectAttribute>())
				types.Add(element);
			return;
		}
		for (let declaration in Type.TypeDeclarations)
		{
			if (!Registry.IsVisible(declaration))
				continue;
			if (!declaration.HasCustomAttribute<XmlObjectAttribute>())
				continue;
			let type = declaration.ResolvedType;
			if (type == null || type.IsValueType || type.IsInterface || type.IsAbstract || type.IsGenericParam)
				continue;
			if (element.IsInterface ? type.ImplementsInterface(element) : type.IsSubtypeOf(element))
				types.Add(type);
		}
	}

	/// The T of a List<T>, or null.
	[Comptime]
	static Type ListElement(Type type) => TypeShapes.ListElement(type);

	/// An [XmlObject] type's element name: its Name, or its type name through its Naming.
	[Comptime]
	static void ElementName(Type type, String name)
	{
		if (type.GetCustomAttribute<XmlObjectAttribute>() case .Ok(let attribute))
		{
			if (attribute.Name != null)
				name.Append(attribute.Name);
			else
				ApplyNaming(type.GetName(.. scope .()), attribute.Naming, name);
		}
		else
			name.Append(type.GetName(.. scope .()));
	}

	/// An [XmlObject] type's Namespace, or nothing.
	[Comptime]
	static void TypeNamespace(Type type, String ns)
	{
		if (type.GetCustomAttribute<XmlObjectAttribute>() case .Ok(let attribute) && attribute.Namespace != null)
			ns.Append(attribute.Namespace);
	}

	/// Appends the XML name for `name` (FormatCore's Naming: words split at case changes, keeping
	/// acronyms together, `HTTPPort` as HTTP, Port; underscores also split).
	[Comptime]
	static void ApplyNaming(StringView name, XmlNaming naming, String result)
	{
		Naming.Apply(name, naming, result);
	}
}
