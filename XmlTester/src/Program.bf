using System;
using System.Collections;
using System.IO;
using XmlBeef;

namespace XmlTester;

/// Command-line harness for the conformance suites and benchmarks (see docs/plan.md and
/// docs/test-suites.md §9.1).
///
///   XmlTester [-no-ns] [-events] [-canonical] [file]
///       read XML from `file` (or stdin) and print the W3C suite's canonical form (James Clark's, with
///       Sun's notation block) to stdout; exit 1 with `line:column: message` on stderr if it is not
///       well-formed. `-no-ns` turns namespace processing off (the suite's NAMESPACE="no" cases).
///       `-events` formats straight from the XmlReader's events (the only mode until the document
///       exists); `-canonical` is accepted for the scripts and is the default.
///   Exit status: 0 well-formed, 1 not well-formed, 2 usage or I/O error.
class Program
{
	public static int Main(String[] args)
	{
		bool namespaces = true;
		String path = null;
		for (int i < args.Count)
		{
			let arg = args[i];
			if (arg == "-no-ns")
				namespaces = false;
			else if (arg == "-events" || arg == "-canonical")
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

		var config = XmlReadConfig();
		config.Namespaces = namespaces;
		let reader = scope XmlReader(StringView((char8*)bytes.Ptr, bytes.Count), config);
		let output = scope String();
		if (XmlCanonical.WriteSuiteForm(reader, output) case .Err(let error))
		{
			Console.Error.WriteLine(error.ToString(.. scope .()));
			return 1;
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
