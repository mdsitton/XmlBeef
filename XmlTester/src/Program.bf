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
///   XmlTester -stream N [options] [file]
///       the same, reading `file` (or stdin) as a Stream through an N-byte buffer (N >= 16), into the
///       document or with -events straight from the reader
///   XmlTester [-no-ns] -write [-indent N] [file]
///       print the document in canonical form (XmlDocument.Write), indented by N spaces if given.
///   XmlTester [-no-ns] [-stream N] -roundtrip OUT [file]
///       read with PreserveStyle and write the document back to the file OUT (XmlDocument.WriteFile:
///       in its own encoding); test-roundtrip.sh compares OUT with the input byte for byte.
///   XmlTester [-no-ns] -collect [options] [file]
///       read with XmlReadConfig.CollectErrors: the first error on stderr's first line (the golden
///       one), the others after it.
///   XmlTester [-no-ns] -fuzz SEED ROUNDS [file]
///       ROUNDS random byte mutations of the input, each read with CollectErrors from memory and from a
///       16-byte stream (Fuzz.bf): both must finish, with the same errors and the same document. Exit 4
///       if they differ.
///   XmlTester [-no-ns] -mutate SEED [file]
///       read with PreserveStyle, make random edits (Mutate.bf), write the document, and check that the
///       written text reads back into the edited document; print it. Exit 4 if it reads back
///       differently.
///   XmlTester -bench <document|events> <file-or-dir> <min-samples>
///       the bench/compare harness (Bench.bf): the check line, then the median time of a read
///   XmlTester -bench-loop <document|events|stream|typed|validate> <file-or-dir> <iterations> [no-ns] [no-dtd] [buffer=N]
///       the same operation a fixed number of times, for perf stat and perf record (stream: the
///       events read from a Stream through a buffer of N bytes, 64 KiB by default)
///   XmlTester -memory <large-file> <small-file>
///       what a document holds through long edit sequences, Compact and Clear (Memory.bf)
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
			// Config variations, to measure what each costs: no-ns, no-dtd, buffer=N (the stream mode's)
			var config = XmlReadConfig();
			for (int i = 4; i < args.Count; i++)
			{
				if (args[i] == "no-ns")
					config.Namespaces = false;
				else if (args[i] == "no-dtd")
					config.DtdMode = .Ignore;
				else if (args[i].StartsWith("buffer=") && int.Parse(args[i].Substring(7)) case .Ok(let size))
					config.StreamBufferBytes = size;
			}
			return Bench.Loop(args[1], args[2], count, config);
		}
		if (args.Count == 3 && args[0] == "-memory")
			return Memory.Run(args[1], args[2]);
		bool namespaces = true;
		bool events = false;
		bool rewrite = false;
		bool write = false;
		int indent = 0;
		int streamBuffer = 0;
		String path = null;
		String roundtrip = null;
		int mutateSeed = -1;
		bool collect = false;
		int fuzzSeed = -1;
		int fuzzRounds = 0;
		for (int i < args.Count)
		{
			let arg = args[i];
			if (arg == "-no-ns")
				namespaces = false;
			else if (arg == "-stream" && i + 1 < args.Count && int.Parse(args[i + 1]) case .Ok(let size))
			{
				streamBuffer = size;
				i++;
			}
			else if (arg == "-collect")
				collect = true;
			else if (arg == "-fuzz" && i + 2 < args.Count && int.Parse(args[i + 1]) case .Ok(let seed) && int.Parse(args[i + 2]) case .Ok(let rounds))
			{
				fuzzSeed = seed;
				fuzzRounds = rounds;
				i += 2;
			}
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
			else if (arg == "-roundtrip" && i + 1 < args.Count)
			{
				roundtrip = args[i + 1];
				i++;
			}
			else if (arg == "-mutate" && i + 1 < args.Count && int.Parse(args[i + 1]) case .Ok(let seed))
			{
				mutateSeed = seed;
				i++;
			}
			else if (arg.StartsWith('-'))
			{
				Console.Error.WriteLine($"XmlTester: unknown option {arg}");
				return 2;
			}
			else
				path = arg;
		}

		var config = XmlReadConfig();
		config.Namespaces = namespaces;
		config.StreamBufferBytes = streamBuffer;
		if (roundtrip != null || mutateSeed >= 0)
			config.MetadataMode = .PreserveStyle;
		config.CollectErrors = collect;

		// The input: whole in memory, or with -stream N a Stream read through an N-byte buffer
		let bytes = scope List<uint8>();
		let file = scope FileStream();
		Stream stream = null;
		if (streamBuffer > 0)
		{
			if (path == null)
				stream = Console.In.BaseStream;
			else if (file.Open(path, .Read, .Read) case .Ok)
				stream = file;
			else
			{
				Console.Error.WriteLine($"XmlTester: cannot read {path}");
				return 2;
			}
		}
		else if (path != null)
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
		if (fuzzSeed >= 0)
			return Fuzz.Run(bytes, config, fuzzSeed, fuzzRounds);

		let output = scope String();
		if (events)
		{
			let reader = scope XmlReader();
			if (stream != null)
				reader.Reset(stream, config);
			else
				reader.Reset(input, config);
			if (XmlCanonical.WriteSuiteForm(reader, output) case .Err(let error))
			{
				Console.Error.WriteLine(error.ToString(.. scope .()));
				return 1;
			}
		}
		else
		{
			let doc = scope XmlDocument();
			if ((stream != null ? doc.Read(stream, config) : doc.Read(input, config)) case .Err(let error))
			{
				Console.Error.WriteLine(error.ToString(.. scope .()));
				// With -collect, the rest after the first (the golden one)
				for (int i = 1; i < doc.Errors.Length; i++)
					Console.Error.WriteLine(doc.Errors[i].ToString(.. scope .()));
				return 1;
			}
			if (roundtrip != null)
			{
				if (doc.WriteFile(roundtrip) case .Err(let writeError))
				{
					Console.Error.WriteLine(scope $"cannot write the document: {writeError}");
					return 2;
				}
				return 0;
			}
			if (mutateSeed >= 0)
			{
				int status = Mutate.Run(doc, config, mutateSeed);
				Console.Out.Flush();
				return status;
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
				if (again.Read(written, config) case .Err(let rewriteError))
				{
					Console.Error.WriteLine(scope $"the canonical form was rejected: {rewriteError}");
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
