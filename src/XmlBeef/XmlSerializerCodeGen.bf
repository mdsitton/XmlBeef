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
///
/// The planning (field kinds and roles, claimed names, checks) is in XmlSerializerPlan.bf; this file is
/// the entry point and the emission of code from the plans.
public static class XmlSerializerCodeGen
{
	/// @brief Emit IXmlSerializable into `type`.
	/// @param type A class or struct carrying [XmlObject].
	/// @param naming How names become XML names.
	/// @param elementName The type's element name (XmlObjectAttribute.Name), or empty for its name.
	/// @param namespaceUri The type's namespace, or empty.
	/// @param strict Whether reading rejects what no field maps.
	/// @param showGenerated Whether to emit the code as text too (`XmlGeneratedSource`).
	[Comptime]
	public static void Emit(Type type, XmlNaming naming, StringView elementName, StringView namespaceUri, bool strict, bool showGenerated = false)
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
		ScanChain(type, naming, namespaceUri, ownerName, claimedElements, let elementCount, claimedAttributes, let attributeCount, let allElements, let allAttributes, let mapsText);
		// What the [XmlChildren] list and the strict check see: for a class through virtual properties,
		// so that a base's code also leaves alone what a subclass's fields claim
		if (elementCount > 0)
			read.Insert(0, scope $"static StringView[{elementCount}] sXmlClaimedElements = .({claimedElements});\n");
		if (attributeCount > 0)
			read.Insert(0, scope $"static StringView[{attributeCount}] sXmlClaimedAttributes = .({claimedAttributes});\n");
		StringView elementsExpr;
		StringView attributesExpr;
		StringView allExpr;
		StringView allAttributesExpr;
		StringView textExpr;
		if (type.IsValueType)
		{
			elementsExpr = (elementCount > 0) ? "sXmlClaimedElements" : "default";
			attributesExpr = (attributeCount > 0) ? "sXmlClaimedAttributes" : "default";
			allExpr = allElements ? "true" : "false";
			allAttributesExpr = allAttributes ? "true" : "false";
			textExpr = mapsText ? "true" : "false";
		}
		else
		{
			elementsExpr = "this.XmlClaimedElementNames";
			attributesExpr = "this.XmlClaimedAttributeNames";
			allExpr = "this.XmlTakesAllElements";
			allAttributesExpr = "this.XmlTakesAllAttributes";
			textExpr = "this.XmlMapsText";
			StringView overriding = baseIsObject ? "override" : "virtual";
			read.Insert(0, scope $"protected {overriding} bool XmlTakesAllAttributes => {allAttributes ? "true" : "false"};\n");
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
			case .Map:
				// An unwrapped catch-all leaves alone what the other fields map
				StringView claimed = plan.mWrapped ? "default" : (plan.mMapStyle == .Attributes) ? attributesExpr : (plan.mMapStyle == .KeysAsNames) ? elementsExpr : "default";
				EmitReadMap(read, ownerName, fieldName, plan, claimed);
				EmitWriteMap(write, fieldName, plan, claimed);
			}
		}

		if (strict)
			read.AppendF("\tTry!(XmlBeef.XmlBind.CheckStrict(_node, {}, {}, {}, {}, {}));\n", attributesExpr, elementsExpr, allExpr, allAttributesExpr, textExpr);
		read.Append("\treturn .Ok;\n}\n");
		write.Append("\treturn .Ok;\n}\n");

		Compiler.EmitAddInterface(type, typeof(IXmlSerializable));
		Compiler.EmitTypeBody(type, read);
		Compiler.EmitTypeBody(type, write);
		if (showGenerated)
		{
			let literal = scope String("\"");
			for (let c in scope String()..Append(read)..Append(write).RawChars)
			{
				switch (c)
				{
				case '"': literal.Append("\\\"");
				case '\\': literal.Append("\\\\");
				case '\n': literal.Append("\\n");
				case '\t': literal.Append("\\t");
				default: literal.Append(c);
				}
			}
			literal.Append('"');
			bool hides = false;
			if (baseIsObject && type.BaseType.GetCustomAttribute<XmlObjectAttribute>() case .Ok(let baseObject))
				hides = baseObject.ShowGenerated;
			Compiler.EmitTypeBody(type, scope $"public {hides ? "new " : ""}static StringView XmlGeneratedSource => {literal};\n");
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
		code.AppendF("\t\tfor (let _c in _node.Children)\n\t\t{{\n\t\t\tif (_c.Kind != .Element || XmlBeef.XmlBind.IsClaimedElement(_c, {}))\n\t\t\t\tcontinue;\n", claimedExpr);
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

	/// `XmlBeef.XmlMapStyle.X`.
	[Comptime]
	static void StyleExpr(XmlMapStyle style, String code)
	{
		code.Append("XmlBeef.XmlMapStyle.");
		style.ToString(code);
	}

	/// The key attribute an object value's element carries (TypedEntries, Entries), for the strict check.
	[Comptime]
	static StringView EntryKeyAttribute(FieldPlan plan)
	{
		return (plan.mMapStyle == .TypedEntries || plan.mMapStyle == .Entries) ? plan.mMapKey : "\"\"";
	}

	/// A Dictionary (see XmlMapStyle): the entries of its wrapper, or unwrapped of the element, read into
	/// it after emptying it (owned keys and values deleted on a heap read). Each key is added before its
	/// value is read, so the dictionary owns it if reading fails; the last of repeated keys wins.
	[Comptime]
	static void EmitReadMap(String code, StringView ownerName, StringView name, FieldPlan plan, StringView claimed)
	{
		StringView req = plan.mRequired ? "true" : "false";
		let keyType = plan.mKeyType;
		let valueType = plan.mElement;
		bool objectValue = plan.mElementKind == .Object;
		bool ownsKeys = keyType == typeof(String);
		bool ownsValues = !valueType.IsValueType;
		code.Append("\t{\n\t\tXmlBeef.XmlNode _dn = _node;\n\t\tbool _found = true;\n");
		if (plan.mWrapped)
		{
			code.AppendF("\t\t_found = Try!(XmlBeef.XmlBind.FindElement(_node, {}, {}, {}, out _dn));\n", plan.mName, plan.mNamespace, plan.mAliases.IsEmpty ? req : "false");
			for (int a < plan.mAliases.Count)
				code.AppendF("\t\tif (!_found)\n\t\t\t_found = Try!(XmlBeef.XmlBind.FindElement(_node, {}, {}, {}, out _dn));\n", plan.mAliases[a], plan.mNamespace, (a == plan.mAliases.Count - 1) ? req : "false");
		}
		code.Append("\t\tif (_found)\n\t\t{\n");
		code.AppendF("\t\t\tif (this.{0} == null)\n\t\t\t\tthis.{0} = {1};\n\t\t\telse\n\t\t\t{{\n", name, NewExpr(plan.mType.GetFullName(.. scope .()), "", .. scope .()));
		if (ownsKeys || ownsValues)
		{
			code.AppendF("\t\t\t\tif (_alloc == null)\n\t\t\t\t{{\n\t\t\t\t\tfor (let _old in this.{})\n\t\t\t\t\t{{\n", name);
			if (ownsKeys)
				code.Append("\t\t\t\t\t\tdelete _old.key;\n");
			if (ownsValues)
				code.Append("\t\t\t\t\t\tdelete _old.value;\n");
			code.Append("\t\t\t\t\t}\n\t\t\t\t}\n");
		}
		code.AppendF("\t\t\t\tthis.{}.Clear();\n\t\t\t}}\n\t\t\tlet _m = this.{};\n", name, name);
		let style = StyleExpr(plan.mMapStyle, .. scope .());
		code.AppendF("\t\t\tfor (let _me in XmlBeef.XmlMapEntries(_dn, {}, {}, {}, {}, {}, {}))\n\t\t\t{{\n", style, plan.mMapEntry, plan.mMapKey, plan.mMapValue, plan.mNamespace, claimed);
		code.Append("\t\t\t\tTry!(_me.Check());\n\t\t\t\tif (!_me.mHasValue)\n\t\t\t\t\tcontinue;\n");
		// A TypedEntries entry must be of the value's type (a class's subtypes are dispatched instead)
		if (plan.mMapStyle == .TypedEntries && !(objectValue && !valueType.IsValueType))
			code.AppendF("\t\t\t\tTry!(XmlBeef.XmlBind.CheckEntryType(_me.mElement, {}));\n", plan.mEntryType);
		XmlNaming naming = CaseNaming(plan);
		if (ownsKeys)
		{
			code.AppendF("\t\t\t\tif (_m.TryAddAlt(_me.mKey.mText, let _kp, let _vp))\n\t\t\t\t\t*_kp = {};\n", NewExpr("String", "_me.mKey.mText", .. scope .()));
		}
		else
		{
			code.AppendF("\t\t\t\t{} _key = default;\n\t\t\t\t{{\n\t\t\t\t\tlet _r = _me.mKey;\n", keyType.GetFullName(.. scope .()));
			EmitConvert(code, "\t\t\t\t\t", "_key", false, keyType, plan.mKeyKind, null, naming);
			code.Append("\t\t\t\t}\n\t\t\t\tif (_m.TryAdd(_key, ?, let _vp))\n\t\t\t\t{\n\t\t\t\t}\n");
		}
		// A repeated key: the earlier value goes
		if (ownsValues)
			code.Append("\t\t\t\telse if (_alloc == null)\n\t\t\t\t\tdelete *_vp;\n");
		code.Append("\t\t\t\t*_vp = default;\n");
		if (!objectValue)
		{
			code.Append("\t\t\t\t{\n\t\t\t\t\tlet _r = _me.mValue;\n");
			EmitConvert(code, "\t\t\t\t\t", "(*_vp)", false, valueType, plan.mElementKind, plan.mElementConverter, naming);
			code.Append("\t\t\t\t}\n");
		}
		else if (valueType.IsValueType)
		{
			code.AppendF("\t\t\t\t*_vp = .();\n\t\t\t\tlet _saved = XmlBeef.XmlBind.EnterEntry(_me.mElement, {});\n\t\t\t\tdefer XmlBeef.XmlBind.LeaveEntry(_saved);\n\t\t\t\tTry!((*_vp).XmlRead(_me.mElement, _alloc));\n", EntryKeyAttribute(plan));
		}
		else if (plan.mMapStyle == .TypedEntries)
		{
			// The entry's element name says which subtype it is
			code.AppendF("\t\t\t\tSystem.Compiler.Mixin(XmlBeef.XmlSerializerCodeGen.MapDispatch(typeof({}), ", valueType.GetFullName(.. scope .()));
			AppendLiteral(code, ownerName);
			code.Append(", ");
			AppendLiteral(code, name);
			code.AppendF(", {}));\n", AppendLiteral(.. scope .(), EntryKeyAttribute(plan).Substring(1, EntryKeyAttribute(plan).Length - 2)));
		}
		else
		{
			code.AppendF("\t\t\t\tlet _o = {};\n\t\t\t\t*_vp = _o;\n\t\t\t\tlet _saved = XmlBeef.XmlBind.EnterEntry(_me.mElement, {});\n\t\t\t\tdefer XmlBeef.XmlBind.LeaveEntry(_saved);\n\t\t\t\tTry!(_o.XmlRead(_me.mElement, _alloc));\n",
				NewExpr(valueType.GetFullName(.. scope .()), "", .. scope .()), EntryKeyAttribute(plan));
		}
		code.Append("\t\t\t}\n\t\t}\n\t}\n");
	}

	/// @brief The `switch` that reads a TypedEntries dictionary entry `_me` into its value slot `_vp`, one
	/// case per [XmlObject] type the dictionary's value type can be. Mixed into the generated XmlRead when
	/// it is compiled.
	/// @param element The dictionary's value type.
	/// @param ownerName The type holding the dictionary, for errors.
	/// @param fieldName The dictionary field.
	/// @param key The key attribute's name.
	/// @return The code.
	[Comptime]
	public static String MapDispatch(Type element, String ownerName, String fieldName, String key)
	{
		let types = scope List<Type>();
		ChildTypes(element, types);
		if (!element.IsAbstract && element.HasCustomAttribute<XmlObjectAttribute>() && !types.Contains(element))
			types.Insert(0, element);
		if (types.IsEmpty)
			Fail(ownerName, fieldName, scope $"found no [XmlObject] type for {element.GetFullName(.. scope .())}: mark the value types [XmlObject]");
		let expected = scope String();
		for (let type in types)
		{
			if (!expected.IsEmpty)
				expected.Append(", ");
			ElementName(type, expected);
		}
		let code = new String();
		code.Append("let _saved = XmlBeef.XmlBind.EnterEntry(_me.mElement, ");
		AppendLiteral(code, key);
		code.Append(");\ndefer XmlBeef.XmlBind.LeaveEntry(_saved);\nswitch (_me.mElement.LocalName)\n{\n");
		for (let type in types)
		{
			code.Append("case ");
			AppendLiteral(code, ElementName(type, .. scope .()));
			code.AppendF(":\n\tlet _o = {0};\n\t*_vp = _o;\n\tTry!(_o.XmlRead(_me.mElement, _alloc));\n", NewExpr(type.GetFullName(.. scope .()), "", .. scope .()));
		}
		code.AppendF("default:\n\treturn .Err(XmlBeef.XmlBind.UnknownChild(_me.mElement, \"{}\"));\n}}\n", expected);
		return code;
	}

	/// A Dictionary written in place through an XmlMapWriter: each key into its entry (kept where it is),
	/// new keys appended, keys no longer there removed; a null dictionary removes its wrapper (or,
	/// unwrapped, its entries).
	[Comptime]
	static void EmitWriteMap(String code, StringView name, FieldPlan plan, StringView claimed)
	{
		let valueType = plan.mElement;
		bool objectValue = plan.mElementKind == .Object;
		XmlNaming naming = CaseNaming(plan);
		code.Append("\t{\n");
		EmitRenameAliases(code, plan, false);
		code.Append("\t\tXmlBeef.XmlNode _dn = _node;\n");
		if (plan.mWrapped)
			code.AppendF("\t\tif (this.{0} == null)\n\t\t\tXmlBeef.XmlBind.RemoveElement(_node, {1}, {2});\n\t\telse\n\t\t\t_dn = XmlBeef.XmlBind.ChildElement(_node, {1}, {2});\n\t\tif (this.{0} != null)\n", name, plan.mName, plan.mNamespace);
		let style = StyleExpr(plan.mMapStyle, .. scope .());
		code.AppendF("\t\t{{\n\t\t\tlet _mw = scope XmlBeef.XmlMapWriter(_dn, {}, {}, {}, {}, {}, {});\n", style, plan.mMapEntry, plan.mMapKey, plan.mMapValue, plan.mNamespace, claimed);
		code.AppendF("\t\t\tif (this.{0} != null)\n\t\t\t{{\n\t\t\t\tfor (let _kv in this.{0})\n\t\t\t\t{{\n\t\t\t\t\tlet _k = scope String();\n\t\t\t\t\t{{\n\t\t\t\t\t\tlet _t = _k;\n\t\t\t\t\t\tbool _has = true;\n", name);
		EmitFormat(code, "\t\t\t\t\t\t", "_kv.key", plan.mKeyType, plan.mKeyKind, null, naming);
		// A null key has no text: its entry is left out
		code.Append("\t\t\t\t\t\tif (!_has)\n\t\t\t\t\t\t\tcontinue;\n\t\t\t\t\t}\n");
		StringView entryType = (plan.mMapStyle == .TypedEntries) ? plan.mEntryType : "\"\"";
		if (!objectValue)
		{
			code.Append("\t\t\t\t\t{\n\t\t\t\t\t\tlet _t = scope String();\n\t\t\t\t\t\tbool _has = true;\n");
			EmitFormat(code, "\t\t\t\t\t\t", "_kv.value", valueType, plan.mElementKind, plan.mElementConverter, naming);
			code.AppendF("\t\t\t\t\t\tif (_has)\n\t\t\t\t\t\t\tTry!(_mw.SetScalar(_k, {}, _t));\n\t\t\t\t\t}}\n", entryType);
		}
		else if (valueType.IsValueType)
			code.AppendF("\t\t\t\t\tTry!(_kv.value.XmlWrite(Try!(_mw.ObjectElement(_k, {}, {}))));\n", entryType, AppendLiteral(.. scope .(), TypeNamespace(valueType, .. scope .())));
		else
			code.Append("\t\t\t\t\tif (_kv.value != null)\n\t\t\t\t\t{\n\t\t\t\t\t\tXmlBeef.IXmlSerializable _s = _kv.value;\n\t\t\t\t\t\tTry!(_s.XmlWrite(Try!(_mw.ObjectElement(_k, _s.XmlElementName, _s.XmlElementNamespace))));\n\t\t\t\t\t}\n");
		code.Append("\t\t\t\t}\n\t\t\t}\n\t\t\t_mw.Finish();\n\t\t}\n\t}\n");
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
