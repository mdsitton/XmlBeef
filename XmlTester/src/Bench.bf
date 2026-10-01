using System;
using System.Collections;
using System.IO;
using XmlBeef;

namespace XmlTester;

/// `XmlTester -bench <document|events> <file-or-dir> <min-samples>`: the bench/compare harness (see
/// bench/compare/run.sh). Prints the check line (`check: E A V T`: elements; attributes other than
/// namespace declarations; their values' and the root's text and CDATA lengths in code points), then
/// the median time of one operation: every input read into an XmlDocument (document, the document
/// reused as an application re-reading files would), or every input read through the XmlReader's events
/// (events, each value touched). A directory stands for every file under it, sorted, all read first.
static class Bench
{
	/// `XmlTester -bench-loop <document|events> <file-or-dir> <iterations>`: the operation a fixed
	/// number of times and nothing else, for `perf stat` (instruction counts compare across runs even on
	/// a loaded machine) and `perf record`.
	public static int Loop(StringView mode, StringView path, int iterations, XmlReadConfig config = .())
	{
		let inputs = scope List<List<uint8>>();
		defer { ClearAndDeleteItems!(inputs); }
		if (ReadInputs(path, inputs) case .Err)
		{
			Console.Error.WriteLine($"cannot open {path}");
			return 2;
		}
		let doc = scope XmlDocument();
		let reader = scope XmlReader();
		int64 sink = 0;
		for (int i < iterations)
		{
			for (let input in inputs)
			{
				if (mode == "document")
				{
					doc.ReadBytes(input, config).IgnoreError();
					sink += doc.Root.ChildCount;
					continue;
				}
				if (mode == "validate")
				{
					// The up-front UTF-8 and Char check alone
					let message = scope String();
					sink += XmlChar.FindInvalid((char8*)input.Ptr, 0, input.Count, message, let kind, let length);
					continue;
				}
				reader.Reset(Span<uint8>(input.Ptr, input.Count), config);
				while (reader.Next() case .Ok(let event) && event != .EndOfDocument)
					sink += reader.Value.Length + reader.AttributeCount;
			}
		}
		Console.WriteLine($"sink {sink}");
		return 0;
	}

	public static int Run(StringView mode, StringView path, int minSamples)
	{
		let inputs = scope List<List<uint8>>();
		defer { ClearAndDeleteItems!(inputs); }
		if (ReadInputs(path, inputs) case .Err)
		{
			Console.Error.WriteLine($"cannot open {path}");
			return 2;
		}
		int total = 0;
		for (let input in inputs)
			total += input.Count;

		switch (mode)
		{
		case "document":
			let doc = scope XmlDocument();
			int64[4] check = default;
			for (let input in inputs)
			{
				if (doc.ReadBytes(input) case .Err(let error))
				{
					Console.Error.WriteLine($"parse error: {error}");
					return 1;
				}
				Tally(doc, ref check);
			}
			PrintCheck(check);
			PrintResult(Measure(minSamples, scope () =>
				{
					for (let input in inputs)
						doc.ReadBytes(input).IgnoreError();
				}), total);
		case "events":
			let reader = scope XmlReader();
			int64[4] check = default;
			for (let input in inputs)
			{
				reader.Reset(Span<uint8>(input.Ptr, input.Count), .());
				if (Tally(reader, ref check) case .Err(let error))
				{
					Console.Error.WriteLine($"parse error: {error}");
					return 1;
				}
			}
			PrintCheck(check);
			int64 sink = 0;
			PrintResult(Measure(minSamples, scope [&]() =>
				{
					for (let input in inputs)
					{
						reader.Reset(Span<uint8>(input.Ptr, input.Count), .());
						while (reader.Next() case .Ok(let event) && event != .EndOfDocument)
						{
							if (event == .StartElement)
							{
								for (int i < reader.AttributeCount)
									sink += reader.AttributeValue(i).Length;
							}
							else
								sink += reader.Value.Length;
						}
					}
				}), total);
			if (sink == 0)
				Console.WriteLine();
		default:
			Console.Error.WriteLine($"unknown bench mode {mode}");
			return 2;
		}
		return 0;
	}

	static bool IsNamespaceDeclaration(StringView name) => name == "xmlns" || name.StartsWith("xmlns:");

	static int64 CodePoints(StringView text)
	{
		int64 count = 0;
		for (let c in text)
		{
			if (((uint8)c & 0xC0) != 0x80)
				count++;
		}
		return count;
	}

	static void Tally(XmlDocument doc, ref int64[4] check)
	{
		for (let element in doc.DocumentNode.Descendants)
		{
			check[0]++;
			for (let attribute in element.Attributes)
			{
				if (IsNamespaceDeclaration(attribute.Name))
					continue;
				check[1]++;
				check[2] += CodePoints(attribute.Value);
			}
			for (let child in element.Children)
			{
				if (child.Kind == .Text || child.Kind == .CData)
					check[3] += CodePoints(child.Value);
			}
		}
	}

	static Result<void, XmlParseError> Tally(XmlReader reader, ref int64[4] check)
	{
		while (true)
		{
			switch (Try!(reader.Next()))
			{
			case .StartElement:
				check[0]++;
				for (int i < reader.AttributeCount)
				{
					if (IsNamespaceDeclaration(reader.AttributeName(i)))
						continue;
					check[1]++;
					check[2] += CodePoints(reader.AttributeValue(i));
				}
			case .Text, .CData:
				check[3] += CodePoints(reader.Value);
			case .EndOfDocument:
				return .Ok;
			default:
			}
		}
	}

	static void PrintCheck(int64[4] check)
	{
		Console.WriteLine($"check: {check[0]} {check[1]} {check[2]} {check[3]}");
		Console.Out.Flush();
	}

	/// A file, or every file under a directory (recursively, sorted by path).
	static Result<void> ReadInputs(StringView path, List<List<uint8>> inputs)
	{
		if (Directory.Exists(path))
		{
			let files = scope List<String>();
			defer { ClearAndDeleteItems!(files); }
			CollectFiles(path, files);
			files.Sort(scope (a, b) => String.Compare(a, b, false));
			for (let file in files)
				Try!(ReadOne(file, inputs));
			return .Ok;
		}
		return ReadOne(path, inputs);
	}

	static void CollectFiles(StringView directory, List<String> files)
	{
		for (let entry in Directory.EnumerateFiles(directory))
			files.Add(entry.GetFilePath(.. new .()));
		for (let entry in Directory.EnumerateDirectories(directory))
			CollectFiles(entry.GetFilePath(.. scope .()), files);
	}

	static Result<void> ReadOne(StringView path, List<List<uint8>> inputs)
	{
		let bytes = new List<uint8>();
		if (File.ReadAll(path, bytes) case .Err)
		{
			delete bytes;
			return .Err;
		}
		inputs.Add(bytes);
		return .Ok;
	}

	struct Measurement
	{
		public double mMedianNs;
		public int mSamples;
		public bool mConverged;
	}

	/// The rule shared by every harness in bench/compare (see run.sh): warm up for at least 1 s (at least
	/// one run), then time single runs until at least `minSamples` were taken and at least 60% of them lie
	/// within ±10% of their median ("converged"), or 10 s of measuring or 1000 samples have passed. The
	/// median sample is reported. (KdlTester's Measure.)
	static Measurement Measure(int minSamples, delegate void() op)
	{
		let watch = scope System.Diagnostics.Stopwatch(true);
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

	/// "<ms> ms/op <MB/s> MB/s (n=<samples>, converged|capped)", as bench/compare/c/bench.h prints it.
	static void PrintResult(Measurement m, int bytes)
	{
		double ms = m.mMedianNs / 1e6;
		double mbPerSecond = (double)bytes / 1048576.0 / (ms / 1000.0);
		Console.WriteLine($"{ms:F3} ms/op {mbPerSecond:F1} MB/s (n={m.mSamples}, {m.mConverged ? "converged" : "capped"})");
	}
}
