using System;
using System.Collections;
using System.IO;
using XmlBeef;

namespace XmlTester;

/// Command-line harness for the conformance suites and benchmarks (see docs/plan.md and
/// docs/test-suites.md §9.1).
///
///   XmlTester [-no-ns] [-events | -rewrite] [-canonical] [file]
///       read XML from `file` (or stdin) and print the W3C suite's canonical form (James Clark's, with
///       Sun's notation block) to stdout; exit 1 with `line:column: message` on stderr if it is not
///       well-formed. `-no-ns` turns namespace processing off (the suite's NAMESPACE="no" cases).
///       By default through an XmlDocument; `-events` formats straight from the XmlReader's events;
///       `-rewrite` writes the document in canonical form, reads that back into a new document and
///       prints its suite form (the writer must keep the infoset). `-canonical` is accepted for the
///       scripts and is the default output.
///   XmlTester [-no-ns] -write [-indent N] [file]
///       print the document in canonical form (XmlDocument.Write), indented by N spaces if given.
///   XmlTester -bench <document|events> <file-or-dir> <min-samples>
///       the bench/compare harness (Bench.bf): the check line, then the median time of a read
///   XmlTester -bench-loop <document|events> <file-or-dir> <iterations>
///       the same operation a fixed number of times, for perf stat and perf record
///   Exit status: 0 well-formed, 1 not well-formed, 2 usage or I/O error, 3 the rewritten document
///   was rejected.
class Program
{
	public static int Main(String[] args)
	{
		if (args.Count > 0 && (args[0] == "-bench" || args[0] == "-bench-loop"))
		{
			int count = 0;
			if (args.Count >= 4 && int.Parse(args[3]) case .Ok(let parsed))
				count = parsed;
			if (count < 1)
			{
				Console.Error.WriteLine($"usage: XmlTester {args[0]} <document|events> <file-or-dir> <min-samples|iterations>");
				return 2;
			}
			if (args[0] == "-bench")
				return Bench.Run(args[1], args[2], count);
			// Config variations, to measure what each costs: no-ns, no-dtd
			var config = XmlReadConfig();
			for (int i = 4; i < args.Count; i++)
			{
				if (args[i] == "no-ns")
					config.Namespaces = false;
				else if (args[i] == "no-dtd")
					config.DtdMode = .Ignore;
			}
			return Bench.Loop(args[1], args[2], count, config);
		}
		bool namespaces = true;
		bool events = false;
		bool rewrite = false;
		bool write = false;
		int indent = 0;
		String path = null;
		for (int i < args.Count)
		{
			let arg = args[i];
			if (arg == "-no-ns")
				namespaces = false;
			else if (arg == "-events")
				events = true;
			else if (arg == "-rewrite")
				rewrite = true;
			else if (arg == "-write")
				write = true;
			else if (arg == "-indent" && i + 1 < args.Count && int.Parse(args[i + 1]) case .Ok(let n))
			{
				indent = n;
				i++;
			}
			else if (arg == "-canonical")
			{
			}
			else if (arg.StartsWith('-'))
			{
				Console.Error.WriteLine($"XmlTester: unknown option {arg}");
				return 2;
			}
			else
				path = arg;
		}

		let bytes = scope List<uint8>();
		if (path != null)
		{
			if (File.ReadAll(path, bytes) case .Err)
			{
				Console.Error.WriteLine($"XmlTester: cannot read {path}");
				return 2;
			}
		}
		else if (ReadStdin(bytes) case .Err)
		{
			Console.Error.WriteLine("XmlTester: cannot read stdin");
			return 2;
		}
		StringView input = .((char8*)bytes.Ptr, bytes.Count);

		var config = XmlReadConfig();
		config.Namespaces = namespaces;
		let output = scope String();
		if (events)
		{
			let reader = scope XmlReader(input, config);
			if (XmlCanonical.WriteSuiteForm(reader, output) case .Err(let error))
			{
				Console.Error.WriteLine(error.ToString(.. scope .()));
				return 1;
			}
		}
		else
		{
			let doc = scope XmlDocument();
			if (doc.Read(input, config) case .Err(let error))
			{
				Console.Error.WriteLine(error.ToString(.. scope .()));
				return 1;
			}
			if (write)
			{
				var options = XmlWriteOptions();
				options.Indent = scope String()..Append(' ', indent);
				doc.Write(output, options);
			}
			else if (rewrite)
			{
				let written = scope String();
				doc.Write(written);
				let again = scope XmlDocument();
				if (again.Read(written, config) case .Err(let error))
				{
					Console.Error.WriteLine(scope $"the canonical form was rejected: {error}");
					Console.Error.WriteLine(written);
					return 3;
				}
				XmlCanonical.WriteSuiteForm(again, output);
			}
			else
				XmlCanonical.WriteSuiteForm(doc, output);
		}
		Console.Out.Write(output);
		Console.Out.Flush();
		return 0;
	}

	static Result<void> ReadStdin(List<uint8> bytes)
	{
		let stream = Console.In.BaseStream;
		uint8[4096] buffer = ?;
		while (true)
		{
			switch (stream.TryRead(.(&buffer, buffer.Count)))
			{
			case .Ok(let read):
				if (read <= 0)
					return .Ok;
				bytes.AddRange(Span<uint8>(&buffer, read));
			case .Err:
				return .Err;
			}
		}
	}
}
