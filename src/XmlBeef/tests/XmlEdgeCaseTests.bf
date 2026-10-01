using System;
using System.Collections;
using XmlBeef;
using static XmlBeef.XmlTestUtil;

namespace XmlBeef;

/// The edge cases of docs/spec-reference.md §16, one test each (numbered as there). Results are checked
/// through the suite's canonical form (attributes sorted, `&#10;` for LF, `<a></a>` for `<a/>`).
static class XmlEdgeCaseTests
{
	// Document structure and XML declaration

	[Test] public static void Edge001_EmptyInput() => Rejects("", .InvalidDocumentStructure);
	[Test] public static void Edge002_WhitespaceOnly() => Rejects("  \n", .InvalidDocumentStructure);
	[Test] public static void Edge003_TwoRoots() => Rejects("<a/><b/>", .InvalidDocumentStructure);
	[Test] public static void Edge004_TextBeforeRoot() => Rejects("x<a/>", .InvalidDocumentStructure);
	[Test] public static void Edge005_TextAfterRoot() => Rejects("<a/>x", .InvalidDocumentStructure);
	[Test] public static void Edge006_ReferenceAfterRoot() => Rejects("<a/>&#32;", .InvalidDocumentStructure);
	[Test] public static void Edge007_MiscAfterRoot() => Accepts("<a/>\n<!--c-->\n<?p d?>\n", "<a></a><?p d?>");
	[Test] public static void Edge008_DeclarationAfterSpace() => Rejects(" <?xml version=\"1.0\"?><a/>", .InvalidProcessingInstruction);
	[Test] public static void Edge009_DeclarationAfterComment() => Rejects("<!--c--><?xml version=\"1.0\"?><a/>", .InvalidProcessingInstruction);
	[Test] public static void Edge010_PseudoAttributeOrder() => Rejects("<?xml version=\"1.0\" standalone=\"yes\" encoding=\"UTF-8\"?><a/>", .InvalidXmlDeclaration);
	[Test] public static void Edge011_VersionMissing() => Rejects("<?xml encoding=\"UTF-8\"?><a/>", .InvalidXmlDeclaration);
	[Test] public static void Edge012_DeclarationSpacing() => Accepts("<?xml version = '1.0' encoding=\"utf-8\" ?><a/>", "<a></a>");
	[Test] public static void Edge013_MismatchedQuotes() => Rejects("<?xml version=\"1.0'?><a/>", .InvalidXmlDeclaration);
	[Test] public static void Edge014_Version2() => Rejects("<?xml version=\"2.0\"?><a/>", .InvalidXmlDeclaration);
	[Test] public static void Edge015_Version17() => Accepts("<?xml version=\"1.7\"?><a/>", "<a></a>");
	[Test] public static void Edge016_StandaloneUppercase() => Rejects("<?xml version=\"1.0\" standalone=\"YES\"?><a/>", .InvalidXmlDeclaration);
	[Test] public static void Edge017_EmptyEncoding() => Rejects("<?xml version=\"1.0\" encoding=\"\"?><a/>", .InvalidXmlDeclaration);
	[Test] public static void Edge018_DocTypeAfterRoot() => Rejects("<?xml version=\"1.0\"?><a/><!DOCTYPE a>", .InvalidDocumentStructure);
	[Test] public static void Edge019_TwoDocTypes() => Rejects("<!DOCTYPE a><!DOCTYPE a><a/>", .InvalidDocumentStructure);
	[Test] public static void Edge020_RootNameMismatchIsValidityOnly() => Accepts("<!DOCTYPE a><b/>", "<b></b>");

	// Characters and encoding

	[Test] public static void Edge021_ControlCharacter() => Rejects("<a>\x01</a>", .InvalidChar);
	[Test] public static void Edge022_ControlCharacterReference() => Rejects("<a>&#x1;</a>", .InvalidChar);
	[Test] public static void Edge023_C1AndDelAreLegal() => Accepts("<a>\u{85}\u{7F}\u{9F}</a>", "<a>\u{85}\u{7F}\u{9F}</a>");

	[Test]
	public static void Edge024_Noncharacters()
	{
		Rejects("<a>\u{FFFE}</a>", .InvalidChar);
		Rejects("<a>&#xFFFF;</a>", .InvalidChar);
	}

	[Test] public static void Edge025_SurrogateReference() => Rejects("<a>&#xD800;</a>", .InvalidChar);

	[Test]
	public static void Edge026_HighestCodePoint()
	{
		Accepts("<a>&#x10FFFF;</a>", "<a>\u{10FFFF}</a>");
		Rejects("<a>&#x110000;</a>", .InvalidChar);
	}

	[Test] public static void Edge027_NulReference() => Rejects("<a>&#0;</a>", .InvalidChar);
	[Test] public static void Edge028_LeadingZeros() => Accepts("<a>&#0000065;&#x0041;</a>", "<a>AA</a>");

	[Test]
	public static void Edge029_MalformedCharacterReferences()
	{
		Rejects("<a>&#X41;</a>", .InvalidReference);
		Rejects("<a>&#x;</a>", .InvalidReference);
		Rejects("<a>&#65</a>", .InvalidReference);
		Rejects("<a>&#x41 ;</a>", .InvalidReference);
	}

	[Test] public static void Edge030_Utf8Bom() => Accepts("\xEF\xBB\xBF<a/>", "<a></a>");
	[Test] public static void Edge031_SecondBom() => Rejects("\xEF\xBB\xBF\xEF\xBB\xBF<a/>", .InvalidDocumentStructure);

	[Test]
	public static void Edge032_Utf16LeWithBom()
	{
		let bytes = scope List<uint8>();
		Utf16("<a>é</a>", false, true, bytes);
		Accepts(Bytes(bytes), "<a>é</a>");
	}

	[Test]
	public static void Edge033_Utf16LeWithoutBom()
	{
		let bytes = scope List<uint8>();
		Utf16("<a/>", false, false, bytes);
		Rejects(Bytes(bytes), .InvalidChar);
	}

	[Test]
	public static void Edge034_Utf16BomWithUtf8Declaration()
	{
		let bytes = scope List<uint8>();
		Utf16("<?xml version=\"1.0\" encoding=\"UTF-8\"?><a/>", true, true, bytes);
		Rejects(Bytes(bytes), .UnsupportedEncoding);
	}

	[Test]
	public static void Edge035_IllFormedUtf8()
	{
		Rejects("<a>\xC3\x28</a>", .InvalidEncoding);
		Rejects("<a>\xC0\xAF</a>", .InvalidEncoding);
		Rejects("<a>\xED\xA0\x80</a>", .InvalidEncoding);
	}

	[Test] public static void Edge036_Latin1() => Accepts("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><a>\xE9</a>", "<a>é</a>");
	[Test] public static void Edge037_UnknownEncoding() => Rejects("<?xml version=\"1.0\" encoding=\"x-unknown\"?><a/>", .UnsupportedEncoding);
	[Test] public static void Edge038_ZeroWidthNoBreakSpaceAsText() => Accepts("<a>\u{FEFF}</a>", "<a>\u{FEFF}</a>");

	// End of line

	[Test] public static void Edge039_LineEnds() => Accepts("<a>x\r\ny\rz\r\r\nw</a>", "<a>x&#10;y&#10;z&#10;&#10;w</a>");
	[Test] public static void Edge040_LineEndReferencesKept() => Accepts("<a>&#13;&#10;</a>", "<a>&#13;&#10;</a>");
	[Test] public static void Edge041_CDataLineEnds() => Accepts("<a><![CDATA[x\r\ny]]></a>", "<a>x&#10;y</a>");
	[Test] public static void Edge042_ProcessingInstructionLineEnds() => Accepts("<?p a\r\nb?><a/>", "<?p a\nb?><a></a>");

	// Names and tags

	[Test]
	public static void Edge043_InvalidNameStart()
	{
		Rejects("<1a/>", .UnexpectedChar);
		Rejects("<-a/>", .UnexpectedChar);
		Rejects("<.a/>", .UnexpectedChar);
		Rejects("<·a/>", .UnexpectedChar);
	}

	[Test] public static void Edge044_NameCharacters() => Accepts("<a1-._·/>", "<a1-._·></a1-._·>");

	[Test]
	public static void Edge045_NonAsciiNames()
	{
		Accepts("<é/>", "<é></é>");
		Accepts("<中文/>", "<中文></中文>");
		Accepts("<\u{10000}/>", "<\u{10000}></\u{10000}>");
	}

	[Test]
	public static void Edge046_NotNameCharacters()
	{
		Rejects("<a×/>", .UnexpectedChar);
		Rejects("<a\u{37E}/>", .UnexpectedChar);
		Rejects("<a\u{A0}/>", .UnexpectedChar);
	}

	[Test] public static void Edge047_ReservedPrefixIsLegal() => Accepts("<xmlfoo/>", "<xmlfoo></xmlfoo>");

	[Test]
	public static void Edge048_SpaceAfterOpeningBracket()
	{
		Rejects("< a/>", .UnexpectedChar);
		Rejects("<a></ a>", .UnexpectedChar);
	}

	[Test] public static void Edge049_SpaceInEndTag() => Accepts("<a></a >", "<a></a>");

	[Test]
	public static void Edge050_SplitEmptyElementTag()
	{
		Rejects("<a/ >", .UnexpectedChar);
		Rejects("<a / >", .UnexpectedChar);
	}

	[Test] public static void Edge051_EndTagCase() => Rejects("<a></A>", .MismatchedEndTag);
	[Test] public static void Edge052_ImproperNesting() => Rejects("<a><b></a></b>", .MismatchedEndTag);
	[Test] public static void Edge053_UnclosedAtEnd() => Rejects("<a>", .UnclosedElement);

	// Attributes

	[Test] public static void Edge054_DuplicateAttribute() => Rejects("<a b=\"1\" b=\"2\"/>", .DuplicateAttribute);
	[Test] public static void Edge055_NoSpaceBetweenAttributes() => Rejects("<a b=\"1\"c=\"2\"/>", .UnexpectedChar);
	[Test] public static void Edge056_SpacesAroundEquals() => Accepts("<a b = '1' />", "<a b=\"1\"></a>");

	[Test]
	public static void Edge057_UnquotedOrMissingValue()
	{
		Rejects("<a b=1/>", .UnexpectedChar);
		Rejects("<a b/>", .UnexpectedChar);
	}

	[Test]
	public static void Edge058_AngleBracketsInValues()
	{
		Rejects("<a b=\"<\"/>", .UnexpectedChar);
		Accepts("<a b=\">\"/>", "<a b=\"&gt;\"></a>");
		Accepts("<a b=\"]]>\"/>", "<a b=\"]]&gt;\"></a>");
	}

	[Test]
	public static void Edge059_BareAmpersandInValue()
	{
		Rejects("<a b=\"&\"/>", .InvalidReference);
		Rejects("<a b=\"&amp\"/>", .InvalidReference);
	}

	[Test] public static void Edge060_OtherQuoteInValue() => Accepts("<a b='\"' c=\"'\"/>", "<a b=\"&quot;\" c=\"'\"></a>");
	[Test] public static void Edge061_WhitespaceNormalized() => Accepts("<a b=\"x\ty\nz\r\nw\"/>", "<a b=\"x y z w\"></a>");
	[Test] public static void Edge062_WhitespaceReferencesKept() => Accepts("<a b=\"x&#9;y&#10;z&#13;\"/>", "<a b=\"x&#9;y&#10;z&#13;\"></a>");
	[Test] public static void Edge063_CDataNotTrimmed() => Accepts("<a b=\"  x  \"/>", "<a b=\"  x  \"></a>");
	[Test] public static void Edge064_TokensCollapsed() => Accepts("<!DOCTYPE a [<!ATTLIST a b NMTOKENS #IMPLIED>]><a b=\"  p   q \"/>", "<a b=\"p q\"></a>");
	[Test] public static void Edge065_TokensKeepTabReference() => Accepts("<!DOCTYPE a [<!ATTLIST a b NMTOKENS #IMPLIED>]><a b=\"&#32;p&#9;q\"/>", "<a b=\"p&#9;q\"></a>");
	[Test] public static void Edge066_ReplacementTextWhitespace() => Accepts("<!DOCTYPE a [<!ENTITY t \"x&#9;y\">]><a b=\"&t;\"/>", "<a b=\"x y\"></a>");

	[Test]
	public static void Edge067_DefaultedAttribute()
	{
		Accepts("<!DOCTYPE a [<!ATTLIST a b CDATA \"d\">]><a/>", "<a b=\"d\"></a>");
		let reader = scope XmlReader("<!DOCTYPE a [<!ATTLIST a b CDATA \"d\">]><a c=\"1\"/>");
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Test.Assert(reader.AttributeCount == 2);
		Test.Assert(reader.AttributeName(0) == "c" && reader.IsAttributeSpecified(0));
		Test.Assert(reader.AttributeName(1) == "b" && reader.AttributeValue(1) == "d" && !reader.IsAttributeSpecified(1));
	}

	[Test] public static void Edge068_FirstAttributeDefinitionBinds() => Accepts("<!DOCTYPE a [<!ATTLIST a b CDATA \"1\"><!ATTLIST a b CDATA \"2\">]><a/>", "<a b=\"1\"></a>");
	[Test] public static void Edge069_AngleBracketInDefault() => Rejects("<!DOCTYPE a [<!ATTLIST a b CDATA \"<\">]><a/>", .UnexpectedChar);

	// Character data, CDATA, comments, PIs

	[Test]
	public static void Edge070_CDataEndInText()
	{
		Rejects("<a>]]></a>", .InvalidCData);
		Accepts("<a>]]&gt;</a>", "<a>]]&gt;</a>");
		Accepts("<a>]] ]></a>", "<a>]] ]&gt;</a>");
	}

	[Test] public static void Edge071_CharacterReferencesAreData() => Accepts("<a>&#60;b/&#62;</a>", "<a>&lt;b/&gt;</a>");
	[Test] public static void Edge072_EscapedReference() => Accepts("<a>&amp;lt;</a>", "<a>&amp;lt;</a>");
	[Test] public static void Edge073_CDataMarkup() => Accepts("<a><![CDATA[<&>]]></a>", "<a>&lt;&amp;&gt;</a>");
	[Test] public static void Edge074_CDataBrackets() => Accepts("<a><![CDATA[]]]]></a>", "<a>]]</a>");
	[Test] public static void Edge075_LowercaseCData() => Rejects("<a><![cdata[x]]></a>", .UnexpectedChar);
	[Test] public static void Edge076_CDataBeforeRoot() => Rejects("<![CDATA[x]]><a/>", .InvalidDocumentStructure);
	[Test] public static void Edge077_NestedCData() => Rejects("<a><![CDATA[<![CDATA[x]]>]]></a>", .InvalidCData);
	[Test] public static void Edge078_DoubleHyphenInComment() => Rejects("<!-- a -- b --><a/>", .InvalidComment);
	[Test] public static void Edge079_TripleHyphenEnd() => Rejects("<!-- a ---><a/>", .InvalidComment);

	[Test]
	public static void Edge080_EmptyComments()
	{
		Accepts("<!----><a/>", "<a></a>");
		Rejects("<!---><a/>", .UnexpectedEof);
	}

	[Test] public static void Edge081_MarkupInComment() => Accepts("<!-- <a> & --><a/>", "<a></a>");

	[Test]
	public static void Edge082_ProcessingInstructionData()
	{
		Accepts("<a><?pi?></a>", "<a><?pi ?></a>");
		Accepts("<a><?pi  x ?></a>", "<a><?pi x ?></a>");
	}

	[Test] public static void Edge083_TargetNeedsSpace() => Rejects("<a><?pi?x?></a>", .UnexpectedChar);
	[Test] public static void Edge084_ReservedTarget() => Rejects("<a><?XmL x?></a>", .InvalidProcessingInstruction);
	[Test] public static void Edge085_XmlStylesheet() => Accepts("<?xml-stylesheet href=\"s.css\" type=\"text/css\"?><a/>", "<?xml-stylesheet href=\"s.css\" type=\"text/css\"?><a></a>");

	[Test]
	public static void Edge086_MissingTarget()
	{
		Rejects("<? pi?><a/>", .UnexpectedChar);
		Rejects("<??><a/>", .UnexpectedChar);
	}

	// References and the DTD

	[Test] public static void Edge087_UndeclaredWithoutDtd() => Rejects("<a>&e;</a>", .UndeclaredEntity);
	[Test] public static void Edge088_PredefinedEntities() => Accepts("<a>&amp;&lt;&gt;&apos;&quot;</a>", "<a>&amp;&lt;&gt;'&quot;</a>");
	[Test] public static void Edge089_InternalEntity() => Accepts("<!DOCTYPE a [<!ENTITY e \"v\">]><a>&e;</a>", "<a>v</a>");
	[Test] public static void Edge090_FirstEntityDeclarationBinds() => Accepts("<!DOCTYPE a [<!ENTITY e \"1\"><!ENTITY e \"2\">]><a>&e;</a>", "<a>1</a>");

	[Test]
	public static void Edge091_SkippedEntityWithExternalSubset()
	{
		Accepts("<!DOCTYPE a SYSTEM \"x.dtd\"><a>&e;</a>", "<a></a>");
		let reader = scope XmlReader("<!DOCTYPE a SYSTEM \"x.dtd\"><a>t&e;</a>");
		Expect(reader, .DocType);
		Test.Assert(reader.SystemId == "x.dtd" && reader.HasSystemId && !reader.HasPublicId);
		Expect(reader, .StartElement);
		Expect(reader, .Text);
		Test.Assert(reader.Value == "t");
		Expect(reader, .EntityReference);
		Test.Assert(reader.Name == "e");
		Expect(reader, .EndElement);
		Expect(reader, .EndOfDocument);
	}

	[Test] public static void Edge092_StandaloneMakesUndeclaredFatal() => Rejects("<?xml version=\"1.0\" standalone=\"yes\"?><!DOCTYPE a SYSTEM \"x.dtd\"><a>&e;</a>", .UndeclaredEntity);
	[Test] public static void Edge093_EntityFromParameterEntity() => Accepts("<!DOCTYPE a [<!ENTITY % p \"<!ENTITY e 'v'>\"> %p;]><a>&e;</a>", "<a>v</a>");
	[Test] public static void Edge094_ParameterReferenceMakesUndeclaredValidityOnly() => Accepts("<!DOCTYPE a [<!ENTITY % p \"<!ENTITY e1 'v'>\"> %p;]><a>&e2;</a>", "<a></a>");
	[Test] public static void Edge095_ParameterReferenceInsideDeclaration() => Rejects("<!DOCTYPE a [<!ENTITY % p \"x\"><!ENTITY e \"%p;\">]><a/>", .InvalidEntityReference);
	[Test] public static void Edge096_UndeclaredParameterEntity() => Accepts("<!DOCTYPE a [%p;]><a/>", "<a></a>");

	[Test]
	public static void Edge097_DeclarationsAfterUnreadParameterEntity()
	{
		let input = "<!DOCTYPE a [<!ENTITY % ext SYSTEM \"x.ent\"> %ext; <!ENTITY e \"v\">]><a>&e;</a>";
		Accepts(input, "<a></a>");
		let reader = scope XmlReader(input);
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Expect(reader, .EntityReference);
		Test.Assert(reader.Name == "e");
	}

	[Test] public static void Edge098_PercentInContent() => Accepts("<a>%p;</a>", "<a>%p;</a>");
	[Test] public static void Edge099_ConditionalSectionInInternalSubset() => Rejects("<!DOCTYPE a [<![INCLUDE[ <!ENTITY e \"v\"> ]]>]><a/>", .InvalidDeclaration);
	[Test] public static void Edge100_RecursiveEntity() => Rejects("<!DOCTYPE a [<!ENTITY e \"&e;\">]><a>&e;</a>", .RecursiveEntity);
	[Test] public static void Edge101_UnusedRecursion() => Accepts("<!DOCTYPE a [<!ENTITY a \"&b;\"><!ENTITY b \"&a;\">]><a/>", "<a></a>");
	[Test] public static void Edge102_BypassedUndeclared() => Accepts("<!DOCTYPE a [<!ENTITY e \"&undefined;\">]><a/>", "<a></a>");
	[Test] public static void Edge103_ElementAcrossEntityBoundary() => Rejects("<!DOCTYPE a [<!ENTITY e \"<b>\">]><a>&e;</b></a>", .UnclosedElement);
	[Test] public static void Edge104_ElementInEntity() => Accepts("<!DOCTYPE a [<!ENTITY e \"<b/>\">]><a>&e;</a>", "<a><b></b></a>");
	[Test] public static void Edge105_CharacterReferenceBecomesMarkup() => Rejects("<!DOCTYPE a [<!ENTITY e \"&#60;\">]><a>&e;</a>", .UnexpectedEof);
	[Test] public static void Edge106_DoubleEscapedLessThan() => Accepts("<!DOCTYPE a [<!ENTITY e \"&#38;#60;\">]><a>&e;</a>", "<a>&lt;</a>");
	[Test] public static void Edge107_LtEntityInAttribute() => Accepts("<!DOCTYPE a [<!ENTITY x \"&lt;\">]><a b=\"&x;\"/>", "<a b=\"&lt;\"></a>");
	[Test] public static void Edge108_LessThanFromEntityInAttribute() => Rejects("<!DOCTYPE a [<!ENTITY x \"&#60;\">]><a b=\"&x;\"/>", .UnexpectedChar);
	[Test] public static void Edge109_QuoteFromEntityInAttribute() => Accepts("<!DOCTYPE a [<!ENTITY q \"'\">]><a b='&q;'/>", "<a b=\"'\"></a>");
	[Test] public static void Edge110_ExternalEntityInAttribute() => Rejects("<!DOCTYPE a [<!ENTITY e SYSTEM \"e.xml\">]><a b=\"&e;\"/>", .InvalidEntityReference);
	[Test] public static void Edge111_UnparsedEntityInContent() => Rejects("<!DOCTYPE a [<!NOTATION n SYSTEM \"n\"><!ENTITY e SYSTEM \"e.png\" NDATA n>]><a>&e;</a>", .InvalidEntityReference);
	[Test] public static void Edge112_EntityDeclaredAfterDefault() => Rejects("<!DOCTYPE a [<!ATTLIST a b CDATA \"&e;\"><!ENTITY e \"v\">]><a/>", .UndeclaredEntity);
	[Test] public static void Edge113_AppendixDTricky() => Accepts("<!DOCTYPE a [<!ENTITY % xx '&#37;zz;'><!ENTITY % zz '&#60;!ENTITY t \"ok\">'> %xx;]><a>&t;</a>", "<a>ok</a>");

	[Test]
	public static void Edge114_PublicIdentifiers()
	{
		Rejects("<!DOCTYPE a PUBLIC \"x\"><a/>", .UnexpectedChar);
		Rejects("<!DOCTYPE a PUBLIC \"{\" \"s\"><a/>", .InvalidDeclaration);
	}

	[Test] public static void Edge115_LowercaseDocType() => Rejects("<!doctype a><a/>", .UnexpectedChar);
	[Test] public static void Edge116_ReferenceWithoutSemicolon() => Rejects("<!DOCTYPE a [<!ENTITY e \"x\">]><a>&e</a>", .InvalidReference);

	// Namespaces

	/// The root element's namespace and local name, and its attributes' as `{ns}local` joined by spaces.
	static void ExpectNamespaces(StringView input, StringView elementNs, StringView local, StringView attributes = "", int line = Compiler.CallerLineNum)
	{
		let reader = scope XmlReader(input);
		while (true)
		{
			switch (reader.Next())
			{
			case .Ok(let event):
				if (event != .StartElement)
				{
					if (event == .EndOfDocument)
						Test.FatalError(scope $"line {line}: no element");
					continue;
				}
			case .Err(let error):
				Test.FatalError(scope $"line {line}: `{input}` was rejected: {error}");
			}
			break;
		}
		if (reader.NamespaceUri != elementNs || reader.LocalName != local)
			Test.FatalError(scope $"line {line}: element {{{reader.NamespaceUri}}}{reader.LocalName}, expected {{{elementNs}}}{local}");
		let actual = scope String();
		for (int i < reader.AttributeCount)
		{
			if (i > 0)
				actual.Append(' ');
			actual.AppendF("{{{}}}{}", reader.AttributeNamespaceUri(i), reader.AttributeLocalName(i));
		}
		if (actual != attributes)
			Test.FatalError(scope $"line {line}: attributes `{actual}`, expected `{attributes}`");
	}

	[Test] public static void Edge117_PrefixDeclaredOnSameTag() => ExpectNamespaces("<p:a xmlns:p=\"u\"/>", "u", "a", "{http://www.w3.org/2000/xmlns/}p");
	[Test] public static void Edge118_DeclarationAfterUse() => ExpectNamespaces("<a p:x=\"1\" xmlns:p=\"u\"/>", "", "a", "{u}x {http://www.w3.org/2000/xmlns/}p");

	[Test]
	public static void Edge119_UnboundPrefix()
	{
		Rejects("<p:a/>", .UnboundPrefix);
		Accepts("<p:a/>", "<p:a></p:a>", false);
	}

	[Test] public static void Edge120_DefaultNamespaceNotForAttributes() => ExpectNamespaces("<a xmlns=\"u\" b=\"1\"/>", "u", "a", "{http://www.w3.org/2000/xmlns/}xmlns {}b");
	[Test] public static void Edge121_AttributesUnique() => Rejects("<x xmlns:n1=\"u\" xmlns:n2=\"u\"><y n1:a=\"1\" n2:a=\"2\"/></x>", .DuplicateAttribute);
	[Test] public static void Edge122_PrefixedAndUnprefixedDiffer() => Accepts("<x xmlns:n1=\"u\" xmlns=\"u\"><y a=\"1\" n1:a=\"2\"/></x>", "<x xmlns=\"u\" xmlns:n1=\"u\"><y a=\"1\" n1:a=\"2\"></y></x>");

	[Test]
	public static void Edge123_Undeclaring()
	{
		Rejects("<a xmlns:p=\"\"/>", .InvalidNamespaceDeclaration);
		ExpectNamespaces("<a xmlns=\"\"/>", "", "a", "{http://www.w3.org/2000/xmlns/}xmlns");
	}

	[Test]
	public static void Edge124_XmlPrefix()
	{
		Accepts("<a xmlns:xml=\"http://www.w3.org/XML/1998/namespace\"/>", "<a xmlns:xml=\"http://www.w3.org/XML/1998/namespace\"></a>");
		Rejects("<a xmlns:xml=\"u\"/>", .InvalidNamespaceDeclaration);
	}

	[Test]
	public static void Edge125_ReservedNamespaces()
	{
		Rejects("<a xmlns:xmlns=\"u\"/>", .InvalidNamespaceDeclaration);
		Rejects("<a xmlns:p=\"http://www.w3.org/2000/xmlns/\"/>", .InvalidNamespaceDeclaration);
		Rejects("<a xmlns=\"http://www.w3.org/XML/1998/namespace\"/>", .InvalidNamespaceDeclaration);
	}

	[Test] public static void Edge126_ElementPrefixXmlns() => Rejects("<xmlns:a/>", .InvalidNamespaceDeclaration);
	[Test] public static void Edge127_XmlPrefixNeedsNoDeclaration() => ExpectNamespaces("<a xml:lang=\"en\" xml:space=\"preserve\"/>", "", "a", "{http://www.w3.org/XML/1998/namespace}lang {http://www.w3.org/XML/1998/namespace}space");

	[Test]
	public static void Edge128_InvalidQNames()
	{
		Rejects("<a:b:c/>", .InvalidQName);
		Rejects("<:a/>", .InvalidQName);
		Rejects("<a:/>", .InvalidQName);
		Accepts("<a:b:c/>", "<a:b:c></a:b:c>", false);
		Accepts("<:a/>", "<:a></:a>", false);
		Accepts("<a:/>", "<a:></a:>", false);
	}

	[Test]
	public static void Edge129_ColonsInOtherNames()
	{
		Rejects("<?a:b?><r/>", .InvalidQName);
		Rejects("<!DOCTYPE r [<!ENTITY a:b \"x\">]><r/>", .InvalidQName);
		Accepts("<?a:b?><r/>", "<?a:b ?><r></r>", false);
	}

	[Test] public static void Edge130_ReservedLookingPrefix() => ExpectNamespaces("<xmlfoo:a xmlns:xmlfoo=\"u\"/>", "u", "a", "{http://www.w3.org/2000/xmlns/}xmlfoo");

	[Test]
	public static void Edge131_Shadowing()
	{
		let reader = scope XmlReader("<a xmlns:p=\"u\"><p:b xmlns:p=\"v\"/><p:c/></a>");
		Expect(reader, .StartElement);
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "p:b" && reader.NamespaceUri == "v");
		Expect(reader, .EndElement);
		Test.Assert(reader.Name == "p:b" && reader.NamespaceUri == "v");
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "p:c" && reader.NamespaceUri == "u");
	}

	[Test] public static void Edge132_NamespaceFromEntity() => ExpectNamespaces("<!DOCTYPE svg [<!ENTITY ns_svg \"http://www.w3.org/2000/svg\">]><svg xmlns=\"&ns_svg;\"/>", "http://www.w3.org/2000/svg", "svg", "{http://www.w3.org/2000/xmlns/}xmlns");

	[Test]
	public static void Edge133_NamespaceFromDefaultAttribute()
	{
		let reader = scope XmlReader("<!DOCTYPE a [<!ATTLIST a xmlns:p CDATA #FIXED \"u\">]><a><p:b/></a>");
		Expect(reader, .DocType);
		Expect(reader, .StartElement);
		Expect(reader, .StartElement);
		Test.Assert(reader.Name == "p:b" && reader.NamespaceUri == "u" && reader.LocalName == "b" && reader.Prefix == "p");
	}
}
