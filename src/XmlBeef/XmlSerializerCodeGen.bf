using System;
using System.Collections;
using System.Reflection;

namespace XmlBeef;

/// @brief The compile-time half of [XmlObject]: writes the Beef source of a type's XmlElementName,
/// XmlRead and XmlWrite and hands it to the compiler. Nothing here runs in the finished program; the
/// emitted code calls XmlBind for the per-value work. (KdlBeef's KdlSerializerCodeGen, with XML's
/// roles.)
///
/// Emitted names are fully qualified (the user's file needs no `using XmlBeef`), fields are reached
/// through `this.` and locals start with `_`, so neither clashes with the type's own members. Enums
/// are matched with generated switches over their case names, so they need no reflection at run time.
public static class XmlSerializerCodeGen
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
		Children
	}

	/// @brief Emit IXmlSerializable into `type`.
	/// @param type A class or struct carrying [XmlObject].
	/// @param naming How names become XML names.
	/// @param elementName The type's element name (XmlObjectAttribute.Name), or empty for its name.
	/// @param namespaceUri The type's namespace, or empty.
	/// @param strict Whether reading rejects what no field maps.
	[Comptime]
	public static void Emit(Type type, XmlNaming naming, StringView elementName, StringView namespaceUri, bool strict)
	{
		let read = scope String();
		let write = scope String();
		let ownerName = type.GetFullName(.. scope .());

		// An [XmlObject] base already has the methods: hide them, and read and write its fields first
		bool baseIsObject = type.BaseType != null && type.BaseType != typeof(Object) && type.BaseType.HasCustomAttribute<XmlObjectAttribute>();
		StringView hide = baseIsObject ? "new " : "";

		let name = scope String();
		if (!elementName.IsEmpty)
			name.Append(elementName);
		else
			ApplyNaming(type.GetName(.. scope .()), naming, name);
		CheckName(ownerName, "", name);
		read.AppendF("public {}StringView XmlElementName => {};\n", hide, AppendLiteral(.. scope .(), name));
		read.AppendF("public {}StringView XmlElementNamespace => {};\n", hide, AppendLiteral(.. scope .(), namespaceUri));
		read.AppendF("public {}Result<void, XmlBeef.XmlParseError> XmlRead(XmlBeef.XmlNode _node, System.ITypedAllocator _alloc = null){}\n{{\n", hide, type.IsValueType ? " mut" : "");
		write.AppendF("public {}Result<void, XmlBeef.XmlParseError> XmlWrite(XmlBeef.XmlNode _node)\n{{\n", hide);
		if (baseIsObject)
		{
			read.Append("\tTry!(base.XmlRead(_node, _alloc));\n");
			write.Append("\tTry!(base.XmlWrite(_node));\n");
		}

		// 1. The chain's claimed names, checked for conflicts
		let claimedElements = scope String();
		let claimedAttributes = scope String();
		ScanChain(type, naming, namespaceUri, ownerName, claimedElements, let elementCount, claimedAttributes, let attributeCount, let allElements, let mapsText);
		// What the [XmlChildren] list and the strict check see: for a class through virtual properties,
		// so that a base's code also leaves alone what a subclass's fields claim
		if (elementCount > 0)
			read.Insert(0, scope $"static StringView[{elementCount}] sXmlClaimedElements = .({claimedElements});\n");
		if (attributeCount > 0)
			read.Insert(0, scope $"static StringView[{attributeCount}] sXmlClaimedAttributes = .({claimedAttributes});\n");
		StringView elementsExpr;
		StringView attributesExpr;
		StringView allExpr;
		StringView textExpr;
		if (type.IsValueType)
		{
			elementsExpr = (elementCount > 0) ? "sXmlClaimedElements" : "default";
			attributesExpr = (attributeCount > 0) ? "sXmlClaimedAttributes" : "default";
			allExpr = allElements ? "true" : "false";
			textExpr = mapsText ? "true" : "false";
		}
		else
		{
			elementsExpr = "this.XmlClaimedElementNames";
			attributesExpr = "this.XmlClaimedAttributeNames";
			allExpr = "this.XmlTakesAllElements";
			textExpr = "this.XmlMapsText";
			StringView overriding = baseIsObject ? "override" : "virtual";
			read.Insert(0, scope $"protected {overriding} Span<StringView> XmlClaimedElementNames => {(elementCount > 0) ? "sXmlClaimedElements" : "default"};\n");
			read.Insert(0, scope $"protected {overriding} Span<StringView> XmlClaimedAttributeNames => {(attributeCount > 0) ? "sXmlClaimedAttributes" : "default"};\n");
			read.Insert(0, scope $"protected {overriding} bool XmlTakesAllElements => {allElements ? "true" : "false"};\n");
			read.Insert(0, scope $"protected {overriding} bool XmlMapsText => {mapsText ? "true" : "false"};\n");
		}

		// 2. Every field's plan (its kinds and role), checked before any code is written
		let plans = scope List<FieldPlan>();
		defer { ClearAndDeleteItems!(plans); }
		for (let field in type.GetFields())
		{
			if (IsSerialized(type, field))
				plans.Add(PlanField(field, naming, namespaceUri, ownerName));
		}

		// 3. The code, from the plans
		for (let plan in plans)
		{
			StringView fieldName = plan.mField.Name;
			switch (plan.mRole)
			{
			case .Attribute, .Element, .Text:
				EmitReadScalar(read, fieldName, plan);
				EmitWriteScalar(write, fieldName, plan);
			case .AttributeList:
				EmitReadAttributeList(read, fieldName, plan);
				EmitWriteAttributeList(write, fieldName, plan);
			case .ElementList, .ChildObjects:
				EmitReadElementList(read, fieldName, plan);
				EmitWriteElementList(write, fieldName, plan);
			case .ChildObject:
				EmitReadObject(read, fieldName, plan);
				EmitWriteObject(write, fieldName, plan);
			case .Children:
				EmitReadChildren(read, ownerName, fieldName, plan.mType, plan.mElement, elementsExpr);
				EmitWriteChildren(write, fieldName, plan.mElement, elementsExpr);
			}
		}

		if (strict)
			read.AppendF("\tTry!(XmlBeef.XmlBind.CheckStrict(_node, {}, {}, {}, {}));\n", attributesExpr, elementsExpr, allExpr, textExpr);
		read.Append("\treturn .Ok;\n}\n");
		write.Append("\treturn .Ok;\n}\n");

		Compiler.EmitAddInterface(type, typeof(IXmlSerializable));
		Compiler.EmitTypeBody(type, read);
		Compiler.EmitTypeBody(type, write);
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
		public bool mRequired;
		public Role mRole;
		public Type mType;
		public Kind mKind;
		public Type mConverter;
		public Type mElement;
		public Kind mElementKind;
		public Type mElementConverter;

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
		else
		{
			let typeName = fieldType.GetFullName(.. scope .());
			Fail(ownerName, field.Name, scope $"XML serialization does not support fields of type {typeName}. Supported: bool, integers, float, double, String, enums, [XmlObject] types, and Lists of those; also types with a converter ([XmlConverter] registration or [XmlUseConverter] on the field). Mark the field [XmlIgnore] to leave it out.");
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

	/// Over the whole [XmlObject] chain from `type` (a base's fields are read by its own XmlRead, called
	/// first, but they share the element): the child element and attribute names the fields claim (Beef
	/// literals, comma-separated), which an [XmlChildren] list and the strict check leave alone; whether an
	/// [XmlChildren] list takes the rest, and whether a field maps the text. Stops the build for mappings
	/// that would read the same XML twice: several role attributes on a field, a second [XmlText] or
	/// [XmlChildren], and two attributes or two child elements with one name.
	[Comptime]
	static void ScanChain(Type type, XmlNaming naming, StringView typeNamespace, StringView ownerName, String claimedElements, out int elementCount, String claimedAttributes, out int attributeCount, out bool allElements, out bool mapsText)
	{
		elementCount = 0;
		attributeCount = 0;
		allElements = false;
		mapsText = false;
		String textField = null;
		String childrenField = null;
		// The field that maps each attribute and element name ("Type.Field")
		let attributes = scope Dictionary<String, String>();
		let elements = scope Dictionary<String, String>();
		defer
		{
			delete textField;
			delete childrenField;
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
				if (field.HasCustomAttribute<XmlChildrenAttribute>())
				{
					if (childrenField != null)
						FailType(ownerName, scope $"{fieldPath}: only one [XmlChildren] list is allowed in a type and its [XmlObject] bases (both would read the same elements)");
					childrenField = new .(fieldPath);
					allElements = true;
					continue;
				}
				let names = scope List<String>();
				defer { ClearAndDeleteItems!(names); }
				bool isAttribute = ClaimedNames(field, levelNaming, names);
				let used = isAttribute ? attributes : elements;
				for (let claim in names)
				{
					if (used.TryGetValue(claim, let other))
						FailType(ownerName, scope $"{isAttribute ? "the attribute" : "the element"} `{claim}` is mapped by both {other} and {fieldPath} (the name comes from [XmlName] or the field's name, or for a List of objects from the item type's element name)");
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
	static bool ClaimedNames(FieldInfo field, XmlNaming naming, List<String> names)
	{
		let fieldType = field.FieldType;
		let name = FieldName(field, naming, .. scope .());
		Type useConverter = null;
		if (field.GetCustomAttribute<XmlUseConverterAttribute>() case .Ok(let use))
			useConverter = use.mConverter;
		let kind = LeafKind(fieldType, useConverter, ?);
		bool isAttribute = field.HasCustomAttribute<XmlAttributeAttribute>() || (IsScalar(kind) && !field.HasCustomAttribute<XmlElementAttribute>());
		let element = ListElement(fieldType);
		if (element != null && !field.HasCustomAttribute<XmlArrayAttribute>() && !isAttribute && !field.HasCustomAttribute<XmlNameAttribute>() &&
			LeafKind(element, useConverter, ?) == .Object)
			names.Add(ElementName(element, .. new .()));
		else if (field.GetCustomAttribute<XmlArrayAttribute>() case .Ok(let array) && array.Name != null)
			names.Add(new .(array.Name));
		else
			names.Add(new .(name));
		for (let alias in field.GetCustomAttributes<XmlAliasAttribute>())
			names.Add(new .(alias.mName));
		return isAttribute;
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
		return .Unsupported;
	}

	/// Whether values of `kind` are single XML values.
	[Comptime]
	static bool IsScalar(Kind kind)
	{
		return kind != .Object && kind != .List && kind != .Unsupported;
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
	/// or null. Two such registrations stop the build.
	[Comptime]
	static Type FindRegisteredConverter(Type target)
	{
		Type found = null;
		for (let declaration in Type.TypeDeclarations)
		{
			if (!(declaration.DeclaredInCurrent || declaration.DeclaredInDependency || declaration.AlwaysVisible))
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
	/// concrete class deriving from (or implementing) T.
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
			if (!(declaration.DeclaredInCurrent || declaration.DeclaredInDependency || declaration.AlwaysVisible))
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
	static Type ListElement(Type type)
	{
		if (let specialized = type as SpecializedGenericType)
		{
			if (specialized.UnspecializedType == typeof(List<>))
				return specialized.GetGenericArg(0);
		}
		return null;
	}

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

	/// Appends the XML name for `name`. Words start at an upper-case letter that follows a lower-case
	/// letter or digit, or that ends an acronym (the last capital before a lower-case letter), so
	/// `HTTPPort` splits as HTTP, Port; underscores also split.
	[Comptime]
	static void ApplyNaming(StringView name, XmlNaming naming, String result)
	{
		if (naming == .AsDeclared)
		{
			result.Append(name);
			return;
		}
		int words = 0;
		int i = 0;
		while (i < name.Length)
		{
			if (name[i] == '_')
			{
				i++;
				continue;
			}
			int start = i++;
			while (i < name.Length && name[i] != '_' && !(name[i].IsUpper && (name[i - 1].IsLower || name[i - 1].IsDigit ||
				(name[i - 1].IsUpper && i + 1 < name.Length && name[i + 1].IsLower))))
				i++;

			if (words > 0 && (naming == .KebabCase || naming == .SnakeCase))
				result.Append(naming == .KebabCase ? '-' : '_');
			for (int j = start; j < i; j++)
				result.Append((naming == .CamelCase && words > 0 && j == start) ? name[j].ToUpper : name[j].ToLower);
			words++;
		}
	}

	/// Appends `text` as a Beef string literal.
	[Comptime]
	static void AppendLiteral(String code, StringView text)
	{
		code.Append('"');
		for (let c in text.RawChars)
		{
			switch (c)
			{
			case '"': code.Append("\\\"");
			case '\\': code.Append("\\\\");
			default:
				if ((uint8)c < 0x20)
					Runtime.FatalError(scope $"[XmlName] \"{text}\" contains a control character");
				code.Append(c);
			}
		}
		code.Append('"');
	}

	/// The smallest and largest value of an integer type below 64 unsigned bits, as int64 source
	/// expressions.
	[Comptime]
	static void IntegerRange(Type type, String min, String max)
	{
		int bits = type.Size * 8;
		if (bits == 64)
		{
			min.Append("int64.MinValue");
			max.Append("int64.MaxValue");
		}
		else if (type.IsSigned)
		{
			min.AppendF("{}", -(1L << (bits - 1)));
			max.AppendF("{}", (1L << (bits - 1)) - 1);
		}
		else
		{
			min.Append("0");
			max.AppendF("{}", (1L << bits) - 1);
		}
	}

	[Comptime]
	static bool IsUInt64(Type type)
	{
		return type.IsInteger && type.Size == 8 && !type.IsSigned;
	}

	/// "a, b, c": the enum's case names, for error messages.
	[Comptime]
	static void CaseList(Type enumType, XmlNaming naming, String list)
	{
		for (let field in enumType.GetFields())
		{
			if (!field.IsEnumCase)
				continue;
			if (!list.IsEmpty)
				list.Append(", ");
			ApplyNaming(field.Name, naming, list);
		}
	}

	/// An allocation of `typeName(args)` from the read's allocator when there is one, else the heap.
	[Comptime]
	static void NewExpr(StringView typeName, StringView args, String code)
	{
		code.AppendF("((_alloc != null) ? new:_alloc {0}({1}) : new {0}({1}))", typeName, args);
	}

	/// The naming that enum cases of the field's type are written in: the [XmlObject]'s naming applies to
	/// the type's own names, so cases are written as declared through it too.
	[Comptime]
	static XmlNaming CaseNaming(FieldPlan plan)
	{
		if (plan.mField.DeclaringType.GetCustomAttribute<XmlObjectAttribute>() case .Ok(let attribute))
			return attribute.Naming;
		return .AsDeclared;
	}

	/// Converts the value `_r` into `target` (a field: `this.X`), or appends it to the list `target`.
	[Comptime]
	static void EmitConvert(String code, StringView indent, StringView target, bool toList, Type type, Kind kind, Type converter, XmlNaming naming)
	{
		switch (kind)
		{
		case .Integer:
			let value = scope String();
			if (IsUInt64(type))
				value.Append("Try!(XmlBeef.XmlBind.ToUInt64(_r))");
			else
			{
				let min = scope String();
				let max = scope String();
				IntegerRange(type, min, max);
				value.AppendF("(.)Try!(XmlBeef.XmlBind.ToInteger(_r, {}, {}))", min, max);
			}
			if (toList)
				code.AppendF("{}{}.Add({});\n", indent, target, value);
			else
				code.AppendF("{}{} = {};\n", indent, target, value);
		case .Float:
			if (toList)
				code.AppendF("{}{}.Add((.)Try!(XmlBeef.XmlBind.ToDouble(_r)));\n", indent, target);
			else
				code.AppendF("{}{} = (.)Try!(XmlBeef.XmlBind.ToDouble(_r));\n", indent, target);
		case .Bool:
			if (toList)
				code.AppendF("{}{}.Add(Try!(XmlBeef.XmlBind.ToBool(_r)));\n", indent, target);
			else
				code.AppendF("{}{} = Try!(XmlBeef.XmlBind.ToBool(_r));\n", indent, target);
		case .String:
			if (toList)
				code.AppendF("{}{}.Add({});\n", indent, target, NewExpr("String", "_r.mText", .. scope .()));
			else
				code.AppendF("{0}if ({1} == null)\n{0}\t{1} = {2};\n{0}else\n{0}\t{1}.Set(_r.mText);\n", indent, target, NewExpr("String", "_r.mText", .. scope .()));
		case .Enum:
			let cases = scope String();
			CaseList(type, naming, cases);
			code.AppendF("{}let _s = XmlBeef.XmlBind.EnumText(_r);\n{}switch (_s)\n{}{{\n", indent, indent, indent);
			for (let field in type.GetFields())
			{
				if (!field.IsEnumCase)
					continue;
				code.AppendF("{}case ", indent);
				AppendLiteral(code, ApplyNaming(field.Name, naming, .. scope .()));
				if (toList)
					code.AppendF(": {}.Add(.{});\n", target, field.Name);
				else
					code.AppendF(": {} = .{};\n", target, field.Name);
			}
			code.AppendF("{0}default: return .Err(XmlBeef.XmlBind.UnknownCase(_r, _s, \"{1}\"));\n{0}}}\n", indent, cases);
		case .Converter:
			let converterName = converter.GetFullName(.. scope .());
			if (toList)
				code.AppendF("{0}{1}.Add(default);\n{0}Try!({2}.Read(_r, ref {1}[{1}.Count - 1]));\n", indent, target, converterName);
			else
				code.AppendF("{}Try!({}.Read(_r, ref {}));\n", indent, converterName, target);
		default:
		}
	}

	/// Appends `source` (a field or `_e`) as text to `_t`, or sets `_has` false when there is no value (a
	/// null String, a converter that writes nothing).
	[Comptime]
	static void EmitFormat(String code, StringView indent, StringView source, Type type, Kind kind, Type converter, XmlNaming naming)
	{
		switch (kind)
		{
		case .Integer:
			if (IsUInt64(type))
				code.AppendF("{}XmlBeef.XmlBind.AppendUnsigned(_t, (uint64){});\n", indent, source);
			else
				code.AppendF("{}XmlBeef.XmlBind.AppendInteger(_t, (int64){});\n", indent, source);
		case .Float:
			code.AppendF("{}XmlBeef.XmlBind.AppendDouble(_t, (double){});\n", indent, source);
		case .Bool:
			code.AppendF("{}XmlBeef.XmlBind.AppendBool(_t, {});\n", indent, source);
		case .String:
			code.AppendF("{0}if ({1} != null)\n{0}\t_t.Append({1});\n{0}else\n{0}\t_has = false;\n", indent, source);
		case .Enum:
			code.AppendF("{}switch ({})\n{}{{\n", indent, source, indent);
			for (let field in type.GetFields())
			{
				if (!field.IsEnumCase)
					continue;
				code.AppendF("{}case .{}: _t.Append(", indent, field.Name);
				AppendLiteral(code, ApplyNaming(field.Name, naming, .. scope .()));
				code.Append(");\n");
			}
			code.AppendF("{}}}\n", indent);
		case .Converter:
			code.AppendF("{}if (!{}.Write({}, _t))\n{}\t_has = false;\n", indent, converter.GetFullName(.. scope .()), source, indent);
		default:
		}
	}

	/// Writes `source` through the XmlValueWriter `_w`: its text, or a removal when it has none.
	[Comptime]
	static void EmitSet(String code, StringView indent, StringView source, Type type, Kind kind, Type converter, XmlNaming naming)
	{
		code.AppendF("{0}{{\n{0}\tlet _t = scope String();\n{0}\tbool _has = true;\n", indent);
		EmitFormat(code, scope $"{indent}\t", source, type, kind, converter, naming);
		code.AppendF("{0}\tif (_has)\n{0}\t\t_w.Set(_t);\n{0}\telse\n{0}\t\t_w.Remove();\n{0}}}\n", indent);
	}

	/// The code that finds a scalar's value into `_r` (current name first, then aliases).
	[Comptime]
	static void EmitFind(String code, StringView indent, FieldPlan plan)
	{
		StringView req = plan.mRequired ? "true" : "false";
		StringView firstReq = plan.mAliases.IsEmpty ? req : "false";
		switch (plan.mRole)
		{
		case .Text:
			code.AppendF("{}XmlBeef.XmlValueRef _r;\n{}bool _found = Try!(XmlBeef.XmlBind.FindText(_node, {}, out _r));\n", indent, indent, req);
		case .Element:
			code.AppendF("{0}XmlBeef.XmlValueRef _r = default;\n{0}XmlBeef.XmlNode _c;\n{0}bool _found = Try!(XmlBeef.XmlBind.FindElement(_node, {1}, {2}, {3}, out _c));\n", indent, plan.mName, plan.mNamespace, firstReq);
			for (int a < plan.mAliases.Count)
				code.AppendF("{0}if (!_found)\n{0}\t_found = Try!(XmlBeef.XmlBind.FindElement(_node, {1}, {2}, {3}, out _c));\n", indent, plan.mAliases[a], plan.mNamespace, (a == plan.mAliases.Count - 1) ? req : "false");
			code.AppendF("{0}if (_found)\n{0}\t_r = XmlBeef.XmlBind.ElementValue(_c);\n", indent);
		default:
			code.AppendF("{}XmlBeef.XmlValueRef _r;\n{}bool _found = Try!(XmlBeef.XmlBind.FindAttribute(_node, {}, {}, {}, out _r));\n", indent, indent, plan.mName, plan.mNamespace, firstReq);
			for (int a < plan.mAliases.Count)
				code.AppendF("{0}if (!_found)\n{0}\t_found = Try!(XmlBeef.XmlBind.FindAttribute(_node, {1}, {2}, {3}, out _r));\n", indent, plan.mAliases[a], plan.mNamespace, (a == plan.mAliases.Count - 1) ? req : "false");
		}
	}

	[Comptime]
	static void EmitReadScalar(String code, StringView name, FieldPlan plan)
	{
		code.Append("\t{\n");
		EmitFind(code, "\t\t", plan);
		code.Append("\t\tif (_found)\n\t\t{\n");
		EmitConvert(code, "\t\t\t", scope $"this.{name}", false, plan.mType, plan.mKind, plan.mConverter, CaseNaming(plan));
		code.Append("\t\t}\n\t}\n");
	}

	/// What finds an older name and moves it to the current one before writing.
	[Comptime]
	static void EmitRenameAliases(String code, FieldPlan plan, bool attribute)
	{
		for (let alias in plan.mAliases)
			code.AppendF("\tXmlBeef.XmlBind.{}(_node, {}, {}, {});\n", attribute ? "RenameAttributeAlias" : "RenameElementAlias", plan.mName, alias, plan.mNamespace);
	}

	[Comptime]
	static void EmitWriteScalar(String code, StringView name, FieldPlan plan)
	{
		code.Append("\t{\n");
		switch (plan.mRole)
		{
		case .Text:
			code.Append("\t\tlet _w = XmlBeef.XmlValueWriter.Text(_node);\n");
		case .Element:
			EmitRenameAliases(code, plan, false);
			code.AppendF("\t\tlet _w = XmlBeef.XmlValueWriter.Element(_node, {}, {});\n", plan.mName, plan.mNamespace);
		default:
			EmitRenameAliases(code, plan, true);
			code.AppendF("\t\tlet _w = XmlBeef.XmlValueWriter.Attribute(_node, {}, {});\n", plan.mName, plan.mNamespace);
		}
		EmitSet(code, "\t\t", scope $"this.{name}", plan.mType, plan.mKind, plan.mConverter, CaseNaming(plan));
		code.Append("\t}\n");
	}

	/// Clears a List field whose items are about to be replaced, deleting owned items.
	[Comptime]
	static void EmitReplaceList(String code, StringView indent, StringView name, Type listType, Type element)
	{
		code.AppendF("{0}if (this.{1} == null)\n{0}\tthis.{1} = {2};\n", indent, name, NewExpr(listType.GetFullName(.. scope .()), "", .. scope .()));
		// Without an allocator the list owns its object items (Strings too): delete them before replacing
		if (!element.IsValueType)
			code.AppendF("{0}if (_alloc == null)\n{0}{{\n{0}\tfor (let _old in this.{1})\n{0}\t\tdelete _old;\n{0}}}\n", indent, name);
		code.AppendF("{}this.{}.Clear();\n", indent, name);
	}

	[Comptime]
	static void EmitReadAttributeList(String code, StringView name, FieldPlan plan)
	{
		StringView req = plan.mRequired ? "true" : "false";
		code.AppendF("\t{{\n\t\tXmlBeef.XmlValueRef _value;\n\t\tbool _found = Try!(XmlBeef.XmlBind.FindAttribute(_node, {}, {}, {}, out _value));\n", plan.mName, plan.mNamespace, plan.mAliases.IsEmpty ? req : "false");
		for (int a < plan.mAliases.Count)
			code.AppendF("\t\tif (!_found)\n\t\t\t_found = Try!(XmlBeef.XmlBind.FindAttribute(_node, {}, {}, {}, out _value));\n", plan.mAliases[a], plan.mNamespace, (a == plan.mAliases.Count - 1) ? req : "false");
		code.Append("\t\tif (_found)\n\t\t{\n");
		EmitReplaceList(code, "\t\t\t", name, plan.mType, plan.mElement);
		code.Append("\t\t\tfor (let _r in XmlBeef.XmlBind.Tokens(_value))\n\t\t\t{\n");
		EmitConvert(code, "\t\t\t\t", scope $"this.{name}", true, plan.mElement, plan.mElementKind, plan.mElementConverter, CaseNaming(plan));
		code.Append("\t\t\t}\n\t\t}\n\t}\n");
	}

	[Comptime]
	static void EmitWriteAttributeList(String code, StringView name, FieldPlan plan)
	{
		// The items as one value separated by spaces; a null list removes the attribute
		code.Append("\t{\n");
		EmitRenameAliases(code, plan, true);
		code.AppendF("\t\tlet _w = XmlBeef.XmlValueWriter.Attribute(_node, {}, {});\n", plan.mName, plan.mNamespace);
		code.AppendF("\t\tif (this.{} == null)\n\t\t\t_w.Remove();\n\t\telse\n\t\t{{\n\t\t\tlet _all = scope String();\n\t\t\tfor (let _e in this.{})\n\t\t\t{{\n", name, name);
		code.Append("\t\t\t\tlet _t = scope String();\n\t\t\t\tbool _has = true;\n");
		EmitFormat(code, "\t\t\t\t", "_e", plan.mElement, plan.mElementKind, plan.mElementConverter, CaseNaming(plan));
		code.Append("\t\t\t\tif (!_has)\n\t\t\t\t\tcontinue;\n\t\t\t\tif (_all.Length > 0)\n\t\t\t\t\t_all.Append(' ');\n\t\t\t\t_all.Append(_t);\n\t\t\t}\n\t\t\t_w.Set(_all);\n\t\t}\n\t}\n");
	}

	/// A List as repeated child elements (scalars as their text, objects as themselves), inside a
	/// wrapper element when it has one.
	[Comptime]
	static void EmitReadElementList(String code, StringView name, FieldPlan plan)
	{
		StringView req = plan.mRequired ? "true" : "false";
		bool wrapped = !plan.mWrapper.IsEmpty;
		code.Append("\t{\n\t\tXmlBeef.XmlNode _p = _node;\n");
		if (wrapped)
			code.AppendF("\t\tbool _found = Try!(XmlBeef.XmlBind.FindElement(_node, {}, {}, {}, out _p));\n", plan.mWrapper, plan.mNamespace, req);
		else
		{
			code.AppendF("\t\tbool _found = XmlBeef.XmlBind.HasElement(_node, {}, {});\n", plan.mName, plan.mNamespace);
			if (plan.mRequired)
			{
				code.AppendF("\t\tif (!_found)\n\t\t\treturn .Err(XmlBeef.XmlBind.MakeError(_node, -1, default, ");
				AppendLiteral(code, scope $"`{plan.mName.Substring(1, plan.mName.Length - 2)}` elements are required");
				code.Append(", .MissingValue));\n");
			}
		}
		code.Append("\t\tif (_found)\n\t\t{\n");
		EmitReplaceList(code, "\t\t\t", name, plan.mType, plan.mElement);
		code.AppendF("\t\t\tfor (let _c in XmlBeef.XmlBind.Elements(_p, {}, {}))\n\t\t\t{{\n", plan.mName, plan.mNamespace);
		if (plan.mRole == .ChildObjects)
		{
			let typeName = plan.mElement.GetFullName(.. scope .());
			if (plan.mElement.IsValueType)
				code.AppendF("\t\t\t\t{0} _o = .();\n\t\t\t\tTry!(_o.XmlRead(_c, _alloc));\n\t\t\t\tthis.{1}.Add(_o);\n", typeName, name);
			else // added before reading, so the list owns it even if reading fails
				code.AppendF("\t\t\t\tlet _o = {0};\n\t\t\t\tthis.{1}.Add(_o);\n\t\t\t\tTry!(_o.XmlRead(_c, _alloc));\n", NewExpr(typeName, "", .. scope .()), name);
		}
		else
		{
			code.Append("\t\t\t\tlet _r = XmlBeef.XmlBind.ElementValue(_c);\n");
			EmitConvert(code, "\t\t\t\t", scope $"this.{name}", true, plan.mElement, plan.mElementKind, plan.mElementConverter, CaseNaming(plan));
		}
		code.Append("\t\t\t}\n\t\t}\n\t}\n");
	}

	[Comptime]
	static void EmitWriteElementList(String code, StringView name, FieldPlan plan)
	{
		// Items into the existing children by position, the rest removed; a null list removes them all
		// (with its wrapper)
		bool wrapped = !plan.mWrapper.IsEmpty;
		code.Append("\t{\n");
		if (wrapped)
			code.AppendF("\t\tif (this.{0} == null)\n\t\t\tXmlBeef.XmlBind.RemoveElement(_node, {1}, {2});\n\t\telse\n\t\t{{\n\t\t\tlet _p = XmlBeef.XmlBind.ChildElement(_node, {1}, {2});\n", name, plan.mWrapper, plan.mNamespace);
		else
			code.Append("\t\t{\n\t\t\tlet _p = _node;\n");
		code.AppendF("\t\t\tvar _cc = XmlBeef.XmlChildCursor(_p, {}, {});\n\t\t\tif (this.{} != null)\n\t\t\t{{\n\t\t\t\tfor (let _e in this.{})\n\t\t\t\t{{\n", plan.mName, plan.mNamespace, name, name);
		if (!plan.mElement.IsValueType)
			code.Append("\t\t\t\t\tif (_e == null)\n\t\t\t\t\t\tcontinue;\n");
		if (plan.mRole == .ChildObjects)
			code.Append("\t\t\t\t\tTry!(_e.XmlWrite(_cc.Next()));\n");
		else
		{
			code.Append("\t\t\t\t\tlet _w = XmlBeef.XmlValueWriter.Text(_cc.Next());\n");
			EmitSet(code, "\t\t\t\t\t", "_e", plan.mElement, plan.mElementKind, plan.mElementConverter, CaseNaming(plan));
		}
		code.Append("\t\t\t\t}\n\t\t\t}\n\t\t\t_cc.Trim();\n\t\t}\n\t}\n");
	}

	[Comptime]
	static void EmitReadObject(String code, StringView name, FieldPlan plan)
	{
		StringView req = plan.mRequired ? "true" : "false";
		code.AppendF("\t{{\n\t\tXmlBeef.XmlNode _c;\n\t\tbool _found = Try!(XmlBeef.XmlBind.FindElement(_node, {}, {}, {}, out _c));\n", plan.mName, plan.mNamespace, plan.mAliases.IsEmpty ? req : "false");
		for (int a < plan.mAliases.Count)
			code.AppendF("\t\tif (!_found)\n\t\t\t_found = Try!(XmlBeef.XmlBind.FindElement(_node, {}, {}, {}, out _c));\n", plan.mAliases[a], plan.mNamespace, (a == plan.mAliases.Count - 1) ? req : "false");
		code.Append("\t\tif (_found)\n\t\t{\n");
		if (!plan.mType.IsValueType)
			code.AppendF("\t\t\tif (this.{0} == null)\n\t\t\t\tthis.{0} = {1};\n", name, NewExpr(plan.mType.GetFullName(.. scope .()), "", .. scope .()));
		code.AppendF("\t\t\tTry!(this.{}.XmlRead(_c, _alloc));\n\t\t}}\n\t}}\n", name);
	}

	[Comptime]
	static void EmitWriteObject(String code, StringView name, FieldPlan plan)
	{
		EmitRenameAliases(code, plan, false);
		// Into the existing child when there is one, so its other content stays
		if (plan.mType.IsValueType)
			code.AppendF("\tTry!(this.{}.XmlWrite(XmlBeef.XmlBind.ChildElement(_node, {}, {})));\n", name, plan.mName, plan.mNamespace);
		else
			code.AppendF("\tif (this.{0} != null)\n\t\tTry!(this.{0}.XmlWrite(XmlBeef.XmlBind.ChildElement(_node, {1}, {2})));\n\telse\n\t\tXmlBeef.XmlBind.RemoveElement(_node, {1}, {2});\n", name, plan.mName, plan.mNamespace);
	}

	[Comptime]
	static void EmitReadChildren(String code, StringView ownerName, StringView name, Type listType, Type element, StringView claimedExpr)
	{
		code.Append("\t{\n");
		EmitReplaceList(code, "\t\t", name, listType, element);
		code.AppendF("\t\tfor (let _c in _node.Children)\n\t\t{{\n\t\t\tif (_c.Kind != .Element || XmlBeef.XmlBind.IsClaimed(_c.LocalName, {}))\n\t\t\t\tcontinue;\n", claimedExpr);
		// The item types are found when this method is compiled, not now: they may derive from the type
		// being generated (a Group holding Rects and Groups), which is not complete yet
		code.AppendF("\t\t\tSystem.Compiler.Mixin(XmlBeef.XmlSerializerCodeGen.ChildrenDispatch(typeof({}), ", element.GetFullName(.. scope .()));
		AppendLiteral(code, ownerName);
		code.Append(", ");
		AppendLiteral(code, name);
		code.Append("));\n\t\t}\n\t}\n");
	}

	/// @brief The `switch` that reads child `_c` into the [XmlChildren] list `fieldName`, one case per
	/// [XmlObject] type the list can hold. Mixed into the generated XmlRead when it is compiled.
	/// @param element The list's item type.
	/// @param ownerName The type holding the list, for errors.
	/// @param fieldName The list field.
	/// @return The code.
	[Comptime]
	public static String ChildrenDispatch(Type element, String ownerName, String fieldName)
	{
		let types = scope List<Type>();
		ChildTypes(element, types);
		if (types.IsEmpty)
			Fail(ownerName, fieldName, scope $"[XmlChildren] found no [XmlObject] type for {element.GetFullName(.. scope .())}: mark the item types [XmlObject]");
		let expected = scope String();
		let seen = scope List<String>();
		defer { ClearAndDeleteItems!(seen); }
		for (let type in types)
		{
			let name = ElementName(type, .. new .());
			for (let other in seen)
			{
				if (other == name)
					Fail(ownerName, fieldName, scope $"[XmlChildren]: two types the list can hold have the element name `{name}`; give one another Name");
			}
			seen.Add(name);
			if (!expected.IsEmpty)
				expected.Append(", ");
			expected.Append(name);
		}
		let code = new String();
		code.Append("switch (_c.LocalName)\n{\n");
		for (let type in types)
		{
			let typeName = type.GetFullName(.. scope .());
			code.Append("case ");
			AppendLiteral(code, ElementName(type, .. scope .()));
			if (type.IsValueType)
				code.AppendF(":\n\t{0} _o = .();\n\tTry!(_o.XmlRead(_c, _alloc));\n\tthis.{1}.Add(_o);\n", typeName, fieldName);
			else
				code.AppendF(":\n\tlet _o = {0};\n\tthis.{1}.Add(_o);\n\tTry!(_o.XmlRead(_c, _alloc));\n", NewExpr(typeName, "", .. scope .()), fieldName);
		}
		code.AppendF("default:\n\treturn .Err(XmlBeef.XmlBind.UnknownChild(_c, \"{}\"));\n}}\n", expected);
		return code;
	}

	[Comptime]
	static void EmitWriteChildren(String code, StringView name, Type element, StringView claimedExpr)
	{
		// Items into the unclaimed children by position, the rest removed; a null list removes them all
		code.AppendF("\t{{\n\t\tvar _fc = XmlBeef.XmlFreeChildCursor(_node, {});\n\t\tif (this.{} != null)\n\t\t{{\n\t\t\tfor (let _e in this.{})\n\t\t\t{{\n", claimedExpr, name, name);
		if (element.IsValueType)
			code.Append("\t\t\t\tTry!(_e.XmlWrite(_fc.Next(_e.XmlElementName, _e.XmlElementNamespace)));\n");
		else
		{
			// The item's own type decides its element name and fields: call through the interface, which
			// dispatches on it (an [XmlObject] subclass hides its base's methods rather than overriding)
			if (element.HasCustomAttribute<XmlObjectAttribute>())
				code.Append("\t\t\t\tif (_e == null)\n\t\t\t\t\tcontinue;\n\t\t\t\tXmlBeef.IXmlSerializable _s = _e;\n");
			else
				code.Append("\t\t\t\tlet _s = _e as XmlBeef.IXmlSerializable;\n\t\t\t\tif (_s == null)\n\t\t\t\t\tcontinue;\n");
			code.Append("\t\t\t\tTry!(_s.XmlWrite(_fc.Next(_s.XmlElementName, _s.XmlElementNamespace)));\n");
		}
		code.Append("\t\t\t}\n\t\t}\n\t\t_fc.Trim();\n\t}\n");
	}
}
