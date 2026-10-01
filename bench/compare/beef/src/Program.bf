using System;
using System.Collections;
using System.Diagnostics;
using System.IO;

namespace XmlBeefBench;

/// Benchmarks the existing Beef XML libraries (the pinned clones in ../deps), built into one program:
///
///   XmlBeefBench <beef-lang-xml|xml-beef|beefxml> <file-or-dir> <min-samples>
///
///   beef-lang-xml - HorseTrain/Beef-Lang-XML: XMLToken.ParseTokens then XMLFile.ParseFromTokens into
///                   its element tree, from a String (decoded outside the timing). It splits text into
///                   words and decodes no references, so its figures cannot match; it also prints a line
///                   per parse (its own Console.WriteLine).
///   xml-beef      - LauraRozier/Xml-Beef (a port of Delphi's VerySimpleXml): Xml.LoadFromStream over the
///                   bytes into its node tree, PreserveWhitespace on. Hangs, with growing memory, on
///                   any construct longer than its 4,096-char buffer (run.sh limits its memory).
///   beefxml       - Rune-Magic/BeefXml's pull reader (XmlReader.ParseNext over a MarkupSource over a
///                   StreamReader over the bytes, BOM detected), with its trimming and whitespace
///                   skipping off (Options RequireSemicolon | ValidateChars). Its document builder aborts
///                   on every document, so only the reader is measured. It still skips the
///                   whitespace before every token, so its text figure is not compared ("-").
///
/// An input is a file or a directory (every file under it; one run parses each once). Prints the check
/// line (see ../run.sh) first. Timings follow the rule every harness in bench/compare uses (Measure).
class Program
{
	struct Measurement
	{
		public double mMedianNs;
		public int mSamples;
		public bool mConverged;
	}

	/// Warm up for at least 1 s (at least one run), then time single runs until at least `minSamples`
	/// were taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed.
	/// (From TomlBeef's bench/compare/beef.)
	static Measurement Measure(int minSamples, delegate void() op)
	{
		let watch = scope Stopwatch(true);
		repeat
			op();
		while (watch.Elapsed.TotalSeconds < 1);

		let samples = scope List<double>();
		let sorted = scope List<double>();
		watch.Restart();
		while (true)
		{
			let t0 = watch.Elapsed.Ticks;
			op();
			samples.Add((watch.Elapsed.Ticks - t0) * 100.0); // TimeSpan ticks are 100 ns
			sorted.Clear();
			sorted.AddRange(samples);
			sorted.Sort(scope (a, b) => a <=> b);
			int n = sorted.Count;
			double median = (n % 2 == 1) ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
			if (n >= minSamples)
			{
				int within = 0;
				for (let s in samples)
				{
					if (s >= median * 0.9 && s <= median * 1.1)
						within++;
				}
				if (within >= 0.6 * n)
					return .() { mMedianNs = median, mSamples = n, mConverged = true };
			}
			if (n >= 1000 || watch.Elapsed.TotalSeconds >= 10)
				return .() { mMedianNs = median, mSamples = n, mConverged = false };
		}
	}

	/// elements, attributes (without namespace declarations), attribute value chars, text chars
	struct Check
	{
		public int mElements;
		public int mAttributes;
		public int mAttrChars;
		public int mTextChars;
	}

	/// Code points in UTF-8 text
	static int Chars(StringView s)
	{
		int n = 0;
		for (let c in s.RawChars)
		{
			if (((uint8)c & 0xC0) != 0x80)
				n++;
		}
		return n;
	}

	static bool IsXmlns(StringView name) => name == "xmlns" || name.StartsWith("xmlns:");

	// ---- Inputs ----

	static void FindFiles(StringView dir, List<String> files)
	{
		let found = scope List<String>();
		for (let entry in Directory.EnumerateFiles(dir))
			found.Add(entry.GetFilePath(.. new String()));
		found.Sort(scope (a, b) => a <=> b);
		files.AddRange(found);
		let subdirs = scope List<String>();
		defer { ClearAndDeleteItems!(subdirs); }
		for (let entry in Directory.EnumerateDirectories(dir))
			subdirs.Add(entry.GetFilePath(.. new String()));
		subdirs.Sort(scope (a, b) => a <=> b);
		for (let subdir in subdirs)
			FindFiles(subdir, files);
	}

	// ---- Beef-Lang-XML ----

	static void CountLangXml(XML.XMLElement e, ref Check c)
	{
		c.mElements++;
		for (let name in e.[Friend]AllAttributes)
		{
			if (IsXmlns(name))
				continue;
			c.mAttributes++;
			c.mAttrChars += Chars(e.GetAttribute(name));
		}
		for (let word in e.Data)
			c.mTextChars += Chars(word);
		for (let child in e.[Friend]Children)
			CountLangXml(child, ref c);
	}

	static void ParseLangXml(String text, Check* check)
	{
		let tokens = XML.XMLToken.ParseTokens(text);
		let file = scope XML.XMLFile();
		file.ParseFromTokens(tokens);
		if (check != null)
		{
			for (let e in file.RootElements)
				CountLangXml(e, ref *check);
		}
		// Token strings live on the library's global garbage list, which XMLEnd frees
		delete tokens;
		file.ClearMemory();
		XML.StringMethods.XMLEnd();
	}

	// ---- Xml-Beef ----

	static void CountXmlBeef(Xml_Beef.XmlNode node, ref Check c)
	{
		switch (node.NodeType)
		{
		case .Element:
			c.mElements++;
			for (let a in node.AttributeList)
			{
				if (IsXmlns(a.Name))
					continue;
				c.mAttributes++;
				c.mAttrChars += Chars(a.Value);
			}
			for (let child in node.ChildNodes)
				CountXmlBeef(child, ref c);
		case .Text, .CDataSection:
			c.mTextChars += Chars(node.Text);
		default:
		}
	}

	static void ParseXmlBeef(List<uint8> data, Check* check)
	{
		let stream = scope MemoryStream(data, false);
		let xml = scope Xml_Beef.Xml();
		xml.PreserveWhitespace = true;
		xml.LoadFromStream(stream);
		if (check != null)
		{
			for (let node in xml.ChildNodes)
				CountXmlBeef(node, ref *check);
		}
	}

	// ---- BeefXml ----

	static bool ParseBeefXml(List<uint8> data, Check* check)
	{
		let stream = scope MemoryStream(data, false);
		let streamReader = scope StreamReader(stream, .UTF8, true, 4096);
		let source = scope Xml.MarkupSource(streamReader, "input");
		let reader = scope Xml.XmlReader(source, .RequireSemicolon | .ValidateChars);
		if (reader.ParseHeader() case .Err)
			return false;
		Check c = default;
		int depth = 0;
		bool first = true;
		loop: while (true)
		{
			switch (reader.ParseNext(first))
			{
			case .OpeningTag:
				c.mElements++;
				depth++;
			case .OpeningEnd(let bodyless):
				if (bodyless)
					depth--;
			case .ClosingTag:
				depth--;
			case .Attribute(let name, let value):
				if (!IsXmlns(name))
				{
					c.mAttributes++;
					c.mAttrChars += (check != null) ? Chars(value) : value.Length;
				}
			case .CharacterData(let text):
				if (depth > 0)
					c.mTextChars += (check != null) ? Chars(text) : text.Length;
			case .EOF:
				break loop;
			case .Err:
				return false;
			default:
			}
			first = false;
		}
		if (check != null)
		{
			check.mElements += c.mElements;
			check.mAttributes += c.mAttributes;
			check.mAttrChars += c.mAttrChars;
			check.mTextChars += c.mTextChars;
		}
		return true;
	}

	public static int Main(String[] args)
	{
		if (args.Count < 3)
		{
			Console.Error.WriteLine("usage: XmlBeefBench <beef-lang-xml|xml-beef|beefxml> <file-or-dir> <min-samples>");
			return 2;
		}
		let lib = args[0];
		let files = scope List<String>();
		defer { ClearAndDeleteItems!(files); }
		if (Directory.Exists(args[1]))
			FindFiles(args[1], files);
		else
			files.Add(new String(args[1]));
		let docs = scope List<List<uint8>>();
		defer { ClearAndDeleteItems!(docs); }
		let texts = scope List<String>();
		defer { ClearAndDeleteItems!(texts); }
		int total = 0;
		for (let f in files)
		{
			let data = new List<uint8>();
			if (File.ReadAll(f, data) case .Err)
			{
				Console.Error.WriteLine(scope $"cannot read {f}");
				delete data;
				return 2;
			}
			total += data.Count;
			docs.Add(data);
			if (lib == "beef-lang-xml")
				texts.Add(File.ReadAllText(f, .. new String()));
		}
		int minSamples = int.Parse(args[2]) case .Ok(let v) ? v : 5;

		Check check = default;
		delegate void() op;
		switch (lib)
		{
		case "beef-lang-xml":
			for (let t in texts)
				ParseLangXml(t, &check);
			op = scope:: () => { for (let t in texts) ParseLangXml(t, null); };
		case "xml-beef":
			for (let d in docs)
				ParseXmlBeef(d, &check);
			op = scope:: () => { for (let d in docs) ParseXmlBeef(d, null); };
		case "beefxml":
			for (let d in docs)
			{
				if (!ParseBeefXml(d, &check))
				{
					Console.Error.WriteLine("parse error");
					return 1;
				}
			}
			op = scope:: () => { for (let d in docs) ParseBeefXml(d, null); };
		default:
			Console.Error.WriteLine(scope $"unknown library {lib}");
			return 2;
		}
		// BeefXml's reader skips the whitespace before every token whatever its options
		// (ParseNext starts with Source.ConsumeWhitespace()), so its text figure is not compared
		if (lib == "beefxml")
			Console.WriteLine($"check: {check.mElements} {check.mAttributes} {check.mAttrChars} -");
		else
			Console.WriteLine($"check: {check.mElements} {check.mAttributes} {check.mAttrChars} {check.mTextChars}");
		Console.Out.Flush();
		let m = Measure(minSamples, op);
		double ms = m.mMedianNs / 1e6;
		Console.WriteLine(scope String()..AppendF("{0:F3} ms/op {1:F1} MB/s (n={2}, {3})", ms, total / 1048576.0 / (ms / 1000.0),
			m.mSamples, m.mConverged ? "converged" : "capped"));
		return 0;
	}
}
