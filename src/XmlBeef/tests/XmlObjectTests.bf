using System;
using System.Collections;
using XmlBeef;

namespace XmlBeef.Tests;

enum TestLevel
{
	Debug,
	Info,
	WarningOnly
}

[XmlObject(Naming = .KebabCase)]
class TestServer
{
	public String Host ~ delete _;
	public int32 Port;
	[XmlText] public String Note ~ delete _;
}

[XmlObject(Name = "config", Naming = .KebabCase)]
class TestConfig
{
	[XmlRequired] public String Id ~ delete _;
	public int32 PoolSize = 4;
	public uint64 Big;
	public bool Enabled;
	public TestLevel Level = .Info;
	public double Ratio;
	[XmlElement] public String Name ~ delete _;
	[XmlElement, XmlAlias("descr")] public String Description ~ delete _;
	[XmlAttribute] public List<int32> Ports ~ delete _;
	public List<String> Tag ~ DeleteContainerAndItems!(_);
	[XmlArray(Item = "host")] public List<String> Hosts ~ DeleteContainerAndItems!(_);
	public TestServer Main ~ delete _;
	[XmlArray] public List<TestServer> Servers ~ DeleteContainerAndItems!(_);
	[XmlIgnore] public int NotMapped = 7;
}

[XmlObject(Name = "pt")]
struct TestPoint
{
	public int32 x;
	public int32 y;
}

[XmlObject(Name = "path")]
class TestPathData
{
	public List<TestPoint> Points ~ delete _;
}

// Dictionaries in every XmlMapStyle

[XmlObject(Name = "pet")]
abstract class TestPet
{
}

// Strict: the entry's key attribute (`name`) is allowed on it
[XmlObject(Name = "cat", Strict = true)]
class TestCat : TestPet
{
	public int32 lives;
}

[XmlObject(Name = "dog")]
class TestDog : TestPet
{
	public String breed ~ delete _;
}

[XmlObject(Name = "settings")]
class TestSettings
{
	public String known ~ delete _;
	public Dictionary<String, int32> limits ~ DeleteDictionaryAndKeys!(_);
	[XmlMap(Style = .Entries, Entry = "add", Value = "value")] public Dictionary<String, String> appSettings ~ DeleteDictionaryAndKeysAndValues!(_);
	[XmlMap(Style = .KeyValueElements)] public Dictionary<int32, String> byNumber ~ DeleteDictionaryAndValues!(_);
	[XmlMap(Style = .KeysAsNames)] public Dictionary<TestLevel, bool> flags ~ delete _;
	[XmlMap(Style = .Attributes)] public Dictionary<String, double> sizes ~ DeleteDictionaryAndKeys!(_);
	public Dictionary<String, TestPet> pets ~ DeleteDictionaryAndKeysAndValues!(_);
	[XmlMap(Style = .Attributes, Wrapped = false)] public Dictionary<String, String> other ~ DeleteDictionaryAndKeysAndValues!(_);
}

/// For reads into an allocator: no destructors, the allocator owns what the read creates.
[XmlObject(Name = "arena")]
class TestArena
{
	public String name;
	public List<String> item;
	public TestArenaChild child;
}

[XmlObject(Name = "child")]
class TestArenaChild
{
	public String color;
}

/// A length with a unit: `12px`.
struct TestLength
{
	public double mAmount;
	public String mUnit;
}

[XmlConverter(typeof(TestLength))]
struct TestLengthXml : IXmlConverter<TestLength>
{
	public static Result<void, XmlParseError> Read(XmlValueRef value, ref TestLength target)
	{
		StringView text = value.mText;
		int split = 0;
		while (split < text.Length && (text[split].IsDigit || text[split] == '.' || text[split] == '-'))
			split++;
		double amount = 0;
		if (split > 0 && double.Parse(text.Substring(0, split)) case .Ok(let parsed))
			amount = parsed;
		else
			return .Err(value.MakeError(scope $"expected a length such as 12px, found `{text}`"));
		target.mAmount = amount;
		target.mUnit = text.Substring(split) == "em" ? "em" : "px";
		return .Ok;
	}

	public static bool Write(TestLength value, String output)
	{
		XmlBind.AppendDouble(output, value.mAmount);
		output.Append(value.mUnit);
		return true;
	}
}

// Shapes for [XmlChildren], in the SVG namespace

[XmlObject(Namespace = "http://www.w3.org/2000/svg")]
abstract class TestShape
{
	public String id ~ delete _;
}

[XmlObject(Name = "rect", Namespace = "http://www.w3.org/2000/svg")]
class TestRect : TestShape
{
	public double x;
	public double y;
	public TestLength width;
}

[XmlObject(Name = "circle", Namespace = "http://www.w3.org/2000/svg")]
class TestCircle : TestShape
{
	public double r;
}

[XmlObject(Name = "g", Namespace = "http://www.w3.org/2000/svg")]
class TestGroup : TestShape
{
	[XmlChildren] public List<TestShape> children ~ DeleteContainerAndItems!(_);
}

[XmlObject(Name = "svg", Namespace = "http://www.w3.org/2000/svg", Strict = true)]
class TestSvg
{
	public double width;
	[XmlName("href", Namespace = "http://www.w3.org/1999/xlink")] public String link ~ delete _;
	[XmlElement] public String title ~ delete _;
	[XmlChildren] public List<TestShape> shapes ~ DeleteContainerAndItems!(_);
}

static class XmlObjectTests
{
	static void ExpectError(Result<void, XmlParseError> result, XmlErrorKind kind, StringView fragment, int line = Compiler.CallerLineNum)
	{
		switch (result)
		{
		case .Ok:
			Test.FatalError(scope $"line {line}: no error, expected {kind}");
		case .Err(let error):
			let text = error.ToString(.. scope .());
			if (error.mKind != kind || !text.Contains(fragment))
				Test.FatalError(scope $"line {line}: got {error.mKind}: {text}");
		}
	}

	const String cConfig = """
		<config id="c1" pool-size="16" big="18446744073709551615" enabled="1" level="warning-only" ratio=" 2.5 " ports="80 443">
		  <name>Main</name>
		  <descr>older name</descr>
		  <tag>a</tag><tag>b</tag>
		  <hosts><host>x.org</host><host>y.org</host></hosts>
		  <main host="h" port="1">primary</main>
		  <servers><test-server host="s1" port="2"/><test-server host="s2" port="3">n</test-server></servers>
		  <unknown/>
		</config>
		""";

	[Test]
	public static void Read_AllRoles()
	{
		let config = scope TestConfig();
		Test.Assert(XmlSerializer.Read(cConfig, config) case .Ok);
		Test.Assert(config.Id == "c1" && config.PoolSize == 16 && config.Big == uint64.MaxValue && config.Enabled);
		Test.Assert(config.Level == .WarningOnly && config.Ratio == 2.5 && config.Name == "Main" && config.Description == "older name");
		Test.Assert(config.Ports.Count == 2 && config.Ports[0] == 80 && config.Ports[1] == 443);
		Test.Assert(config.Tag.Count == 2 && config.Tag[1] == "b");
		Test.Assert(config.Hosts.Count == 2 && config.Hosts[0] == "x.org");
		Test.Assert(config.Main.Host == "h" && config.Main.Port == 1 && config.Main.Note == "primary");
		Test.Assert(config.Servers.Count == 2 && config.Servers[1].Host == "s2" && config.Servers[1].Note == "n" && config.Servers[0].Note == null);
		Test.Assert(config.NotMapped == 7);
	}

	[Test]
	public static void Read_Errors()
	{
		ExpectError(XmlSerializer.Read("<config/>", scope TestConfig()), .MissingValue, "config: The attribute `id` is required");
		ExpectError(XmlSerializer.Read("<config id='a'\n pool-size='x'/>", scope TestConfig()), .InvalidValue, "2:2: config: pool-size: expected an integer, found `x`");
		ExpectError(XmlSerializer.Read("<config id='a' pool-size='3000000000'/>", scope TestConfig()), .InvalidValue, "outside the range -2147483648 to 2147483647");
		ExpectError(XmlSerializer.Read("<config id='a' big='-1'/>", scope TestConfig()), .InvalidValue, "outside the range 0 to 18446744073709551615");
		ExpectError(XmlSerializer.Read("<config id='a' level='loud'/>", scope TestConfig()), .InvalidValue, "`loud` is not one of debug, info, warning-only");
		ExpectError(XmlSerializer.Read("<config id='a'><main port='p'/></config>", scope TestConfig()), .InvalidValue, "1:22: main: port: expected an integer");
		ExpectError(XmlSerializer.Read("<other/>", scope TestConfig()), .InvalidValue, "expected the root element `config`");
		ExpectError(XmlSerializer.Read("<config", scope TestConfig()), .UnexpectedEof, "");
	}

	[Test]
	public static void Write_NewDocument()
	{
		let config = scope TestConfig();
		config.Id = new .("w");
		config.Level = .Debug;
		config.Name = new .("A & B");
		config.Ports = new .() { 1, 2 };
		config.Tag = new .() { new .("t") };
		config.Main = new .();
		config.Main.Host = new .("m");
		config.Main.Note = new .("x<y");
		config.Servers = new .();
		config.Servers.Add(new .());
		config.Servers[0].Port = 9;
		let output = scope String();
		Test.Assert(XmlSerializer.Write(config, output, .() { Indent = "  " }) case .Ok);
		Test.Assert(output == """
			<config id="w" pool-size="4" big="0" enabled="false" level="debug" ratio="0" ports="1 2">
			  <name>A &amp; B</name>
			  <tag>t</tag>
			  <main host="m" port="0">x&lt;y</main>
			  <servers>
			    <test-server port="9"/>
			  </servers>
			</config>

			""");
		// And back
		let again = scope TestConfig();
		Test.Assert(XmlSerializer.Read(output, again) case .Ok);
		Test.Assert(again.Name == "A & B" && again.Main.Note == "x<y" && again.Servers[0].Port == 9 && again.Ports[1] == 2);
	}

	[Test]
	public static void Write_IntoPreservedDocument()
	{
		let input = "<config id=\"c\"  pool-size='4'>\n  <!-- hosts -->\n  <tag>a</tag>\n  <tag>b</tag>\n</config>\n";
		let doc = scope XmlDocument();
		var config = XmlReadConfig();
		config.MetadataMode = .PreserveStyle;
		Test.Assert(doc.Read(input, config) case .Ok);
		let target = scope TestConfig();
		Test.Assert(target.XmlRead(doc.Root) case .Ok);
		// Writing what was read changes nothing but the attributes the document did not have
		target.PoolSize = 8;
		target.Tag.Add(new .("c"));
		Test.Assert(target.XmlWrite(doc.Root) case .Ok);
		// (new attributes are separated like the last one read: two spaces)
		ExpectWritten(doc, "<config id=\"c\"  pool-size='8'  big=\"0\"  enabled=\"false\"  level=\"info\"  ratio=\"0\">\n  <!-- hosts -->\n  <tag>a</tag>\n  <tag>b</tag>\n  <tag>c</tag>\n</config>\n");
		// Fewer items: the rest go with their indentation
		delete target.Tag.PopBack();
		delete target.Tag.PopBack();
		Test.Assert(target.XmlWrite(doc.Root) case .Ok);
		ExpectWritten(doc, "<config id=\"c\"  pool-size='8'  big=\"0\"  enabled=\"false\"  level=\"info\"  ratio=\"0\">\n  <!-- hosts -->\n  <tag>a</tag>\n</config>\n");
	}

	static void ExpectWritten(XmlDocument doc, StringView expected, int line = Compiler.CallerLineNum)
	{
		let output = doc.Write(.. scope String());
		if (output != expected)
			Test.FatalError(scope $"line {line}: wrote `{output}`");
	}

	const String cSettings = """
		<settings known="k" extra="x" more="y">
		  <limits><int32 name="retries">3</int32><int32 name="timeout">30</int32></limits>
		  <appSettings><add key="mode" value="fast"/><add key="path" value="/bin"/></appSettings>
		  <byNumber><entry><key>1</key><value>one</value></entry><entry><key>2</key><value>two</value></entry></byNumber>
		  <flags><Debug>true</Debug><Info>0</Info></flags>
		  <sizes w="1.5" h="2"/>
		  <pets><cat name="tom" lives="9"/><dog name="rex" breed="lab"/></pets>
		</settings>
		""";

	[Test]
	public static void Maps_EveryStyle()
	{
		let settings = scope TestSettings();
		Test.Assert(XmlSerializer.Read(cSettings, settings) case .Ok);
		Test.Assert(settings.known == "k" && settings.limits.Count == 2 && settings.limits["timeout"] == 30);
		Test.Assert(settings.appSettings["path"] == "/bin" && settings.byNumber[2] == "two");
		Test.Assert(settings.flags[.Debug] && !settings.flags[.Info] && settings.sizes["w"] == 1.5);
		Test.Assert((settings.pets["tom"] as TestCat).lives == 9 && (settings.pets["rex"] as TestDog).breed == "lab");
		// The unwrapped Attributes dictionary takes the attributes no other field maps
		Test.Assert(settings.other.Count == 2 && settings.other["extra"] == "x" && !settings.other.ContainsKey("known"));

		// Written and read back the same
		let output = scope String();
		Test.Assert(XmlSerializer.Write(settings, output) case .Ok);
		let again = scope TestSettings();
		Test.Assert(XmlSerializer.Read(output, again) case .Ok);
		Test.Assert(again.limits["retries"] == 3 && again.appSettings["mode"] == "fast" && again.byNumber[1] == "one");
		Test.Assert(again.flags.Count == 2 && again.sizes["h"] == 2 && again.other["more"] == "y");
		Test.Assert((again.pets["rex"] as TestDog).breed == "lab");
		Test.Assert(output.Contains("<int32 name=\"retries\">3</int32>") && output.Contains("<add key=\"mode\" value=\"fast\"/>"));
		Test.Assert(output.Contains("<entry><key>1</key><value>one</value></entry>") && output.Contains("<Debug>true</Debug>"));
		Test.Assert(output.Contains("<sizes w=\"1.5\" h=\"2\"/>") && output.Contains("<cat name=\"tom\" lives=\"9\"/>"));
	}

	[Test]
	public static void Maps_Errors()
	{
		ExpectError(XmlSerializer.Read("<settings><limits><string name='a'>x</string></limits></settings>", scope TestSettings()), .InvalidValue, "string: expected a `int32` entry");
		ExpectError(XmlSerializer.Read("<settings><limits><int32>1</int32></limits></settings>", scope TestSettings()), .MissingValue, "The attribute `name` is required");
		ExpectError(XmlSerializer.Read("<settings><byNumber><entry><key>x</key><value>v</value></entry></byNumber></settings>", scope TestSettings()), .InvalidValue, "expected an integer");
		ExpectError(XmlSerializer.Read("<settings><flags><Loud>true</Loud></flags></settings>", scope TestSettings()), .InvalidValue, "`Loud` is not one of Debug, Info, WarningOnly");
		ExpectError(XmlSerializer.Read("<settings><pets><bird name='b'/></pets></settings>", scope TestSettings()), .InvalidValue, "unknown element: expected one of");
		// A key that cannot be an XML name, written with KeysAsNames or Attributes
		let settings = scope TestSettings();
		settings.sizes = new .();
		settings.sizes[new .("not a name")] = 1;
		ExpectError(XmlSerializer.Write(settings, scope String()), .InvalidValue, "the key `not a name` cannot be written as an XML name");
	}

	[Test]
	public static void Maps_WrittenInPlace()
	{
		let doc = scope XmlDocument();
		var config = XmlReadConfig();
		config.MetadataMode = .PreserveStyle;
		Test.Assert(doc.Read("<settings>\n  <limits>\n    <int32 name=\"retries\">3</int32>\n    <int32 name=\"timeout\">30</int32>\n  </limits>\n</settings>\n", config) case .Ok);
		let settings = scope TestSettings();
		Test.Assert(settings.XmlRead(doc.Root) case .Ok);
		// Unchanged: the document is as read
		Test.Assert(settings.XmlWrite(doc.Root) case .Ok);
		ExpectWritten(doc, "<settings>\n  <limits>\n    <int32 name=\"retries\">3</int32>\n    <int32 name=\"timeout\">30</int32>\n  </limits>\n</settings>\n");
		// A value changed, a key removed, one added
		settings.limits["timeout"] = 60;
		for (let pair in settings.limits)
		{
			if (pair.key == "retries")
			{
				delete pair.key;
				@pair.Remove();
			}
		}
		settings.limits[new .("depth")] = 2;
		Test.Assert(settings.XmlWrite(doc.Root) case .Ok);
		ExpectWritten(doc, "<settings>\n  <limits>\n    <int32 name=\"timeout\">60</int32>\n    <int32 name=\"depth\">2</int32>\n  </limits>\n</settings>\n");
	}

	[Test]
	public static void Aliases_RenamedOnWrite()
	{
		let doc = scope XmlDocument();
		Test.Assert(doc.Read("<config id='a'><descr>old</descr></config>") case .Ok);
		let config = scope TestConfig();
		Test.Assert(config.XmlRead(doc.Root) case .Ok);
		Test.Assert(config.Description == "old");
		config.Description.Set("new");
		Test.Assert(config.XmlWrite(doc.Root) case .Ok);
		Test.Assert(doc.Root.FirstChild.Name == "description" && doc.Root.FirstChild.Text == "new");
	}

	[Test]
	public static void Allocator_OwnsWhatTheReadMakes()
	{
		// Every String, object and List the read creates comes from the allocator (the type has no
		// destructors: the allocator owns them all)
		let alloc = scope BumpAllocator();
		let target = scope TestArena();
		Test.Assert(XmlSerializer.Read("<arena name='n'><item>a</item><item>b</item><child color='blue'/></arena>", target, .(), alloc) case .Ok);
		Test.Assert(target.name == "n" && target.item.Count == 2 && target.item[1] == "b" && target.child.color == "blue");
	}

	[Test]
	public static void Structs_AndConverters()
	{
		let path = scope TestPathData();
		Test.Assert(XmlSerializer.Read("<path><pt x='1' y='2'/><pt x='3' y='-4'/></path>", path) case .Ok);
		Test.Assert(path.Points.Count == 2 && path.Points[1].y == -4);
		let output = scope String();
		Test.Assert(XmlSerializer.Write(path, output) case .Ok);
		Test.Assert(output == "<path><pt x=\"1\" y=\"2\"/><pt x=\"3\" y=\"-4\"/></path>\n");
	}

	[Test]
	public static void Svg_NamespacesChildrenStrict()
	{
		let input = """
			<svg xmlns="http://www.w3.org/2000/svg" xmlns:xl="http://www.w3.org/1999/xlink" width="10" xl:href="#a">
			  <title>Icon</title>
			  <rect id="r" x="1" y="2" width="3em"/>
			  <g><circle r="5"/></g>
			</svg>
			""";
		let svg = scope TestSvg();
		Test.Assert(XmlSerializer.Read(input, svg) case .Ok);
		Test.Assert(svg.width == 10 && svg.link == "#a" && svg.title == "Icon" && svg.shapes.Count == 2);
		let rect = svg.shapes[0] as TestRect;
		Test.Assert(rect != null && rect.id == "r" && rect.y == 2 && rect.width.mAmount == 3 && rect.width.mUnit == "em");
		let group = svg.shapes[1] as TestGroup;
		Test.Assert(group != null && (group.children[0] as TestCircle).r == 5);

		// Strict: what no field maps is an error
		ExpectError(XmlSerializer.Read("<svg xmlns='http://www.w3.org/2000/svg' height='1'/>", scope TestSvg()), .UnexpectedContent, "svg: height: no field maps this attribute");
		ExpectError(XmlSerializer.Read("<svg xmlns='http://www.w3.org/2000/svg'>text</svg>", scope TestSvg()), .UnexpectedContent, "no field maps the text");
		ExpectError(XmlSerializer.Read("<svg xmlns='http://www.w3.org/2000/svg'><path/></svg>", scope TestSvg()), .InvalidValue, "path: unknown element: expected one of");
		// Another namespace is another element
		ExpectError(XmlSerializer.Read("<svg xmlns='urn:other'/>", scope TestSvg()), .InvalidValue, "expected the root element `svg` in `http://www.w3.org/2000/svg`");

		// Written with the namespaces declared once
		let output = scope String();
		Test.Assert(XmlSerializer.Write(svg, output) case .Ok);
		Test.Assert(output == "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" xmlns:ns0=\"http://www.w3.org/1999/xlink\" ns0:href=\"#a\"><title>Icon</title><rect id=\"r\" x=\"1\" y=\"2\" width=\"3em\"/><g><circle r=\"5\"/></g></svg>\n");
		let again = scope TestSvg();
		Test.Assert(XmlSerializer.Read(output, again) case .Ok);
		Test.Assert(again.link == "#a" && (again.shapes[1] as TestGroup).children.Count == 1);
	}

	[Test]
	public static void Object_ShowGenerated()
	{
		let source = TestShown.XmlGeneratedSource;
		Test.Assert(source.Contains("XmlRead(XmlBeef.XmlNode _node") && source.Contains("XmlWrite(XmlBeef.XmlNode _node"));
		Test.Assert(source.Contains("\"label\"") && source.Contains("\n\t"));
		let shown = scope TestShown();
		Test.Assert(XmlSerializer.Read("<shown label='a \"b\"'/>", shown) case .Ok && shown.label == "a \"b\"");
	}
}

[XmlObject(Name = "shown", ShowGenerated = true)]
class TestShown
{
	public String label = new .() ~ delete _;

	public this()
	{
	}
}
