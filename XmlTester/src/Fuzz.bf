using System;
using System.Collections;
using System.IO;
using XmlBeef;

namespace XmlTester;

/// `XmlTester -fuzz SEED ROUNDS`: random byte mutations of an input (deletions, insertions of markup
/// characters, duplicated or swapped slices), each read with XmlReadConfig.CollectErrors from memory and
/// from a stream through a 16-byte buffer. Both must finish (a hang is the script's timeout, a crash its
/// exit status) and agree: the same errors, and the same document in canonical form.
static class Fuzz
{
	static StringView[?] sInserts = .("<", ">", "&", ";", "\"", "'", "/", "=", "!", "[", "]", "-", "?", "<!--", "-->", "]]>", "<![CDATA[", "</a>", "<a>", "&#", "&amp", "%", "\n", "<?x", "?>", "<!DOCTYPE d [", "\xC3", "\xFF");

	public static int Run(List<uint8> input, XmlReadConfig config, int seed, int rounds)
	{
		let random = scope Random(seed);
		var collect = config;
		collect.CollectErrors = true;
		collect.MetadataMode = .None;
		let mutated = scope List<uint8>();
		for (int round < rounds)
		{
			mutated.Clear();
			mutated.AddRange(input);
			int edits = 1 + random.Next(4);
			for (int e < edits)
				Mutate(mutated, random);

			let memory = scope XmlDocument();
			let memoryResult = memory.ReadBytes(mutated, collect);
			var streamConfig = collect;
			streamConfig.StreamBufferBytes = 16;
			let stream = scope XmlDocument();
			let streamResult = stream.Read(scope MemoryStream(mutated, false), streamConfig);

			// Input the encoding check rejects is validated whole from memory (nothing read) but buffer by
			// buffer from a stream (what comes before it read): both must finish, but they differ
			if (HasEncodingError(memoryResult, memory) || HasEncodingError(streamResult, stream))
				continue;
			let a = Describe(memory, memoryResult, .. scope .());
			let b = Describe(stream, streamResult, .. scope .());
			if (a != b)
			{
				// The first line that differs, and the input saved for a rerun
				var linesA = a.Split('\n');
				var linesB = b.Split('\n');
				while (true)
				{
					let la = linesA.GetNext();
					let lb = linesB.GetNext();
					if (la case .Err && lb case .Err)
						break;
					StringView x = (la case .Ok(let va)) ? va : "(end)";
					StringView y = (lb case .Ok(let vb)) ? vb : "(end)";
					if (x != y)
					{
						Console.Error.WriteLine(scope $"round {round}: memory and stream reads differ");
						Console.Error.WriteLine(scope $"memory: {x}");
						Console.Error.WriteLine(scope $"stream: {y}");
						break;
					}
				}
				if (File.WriteAll("fuzz-failure.xml", mutated) case .Err)
					Console.Error.WriteLine("(could not save fuzz-failure.xml)");
				return 4;
			}
		}
		return 0;
	}

	static bool HasEncodingError(Result<void, XmlParseError> result, XmlDocument doc)
	{
		if (result case .Err(let first) && (first.mKind == .InvalidEncoding || first.mKind == .InvalidChar || first.mKind == .UnsupportedEncoding))
			return true;
		for (let error in doc.Errors)
		{
			if (error.mKind == .InvalidEncoding || error.mKind == .InvalidChar || error.mKind == .UnsupportedEncoding)
				return true;
		}
		return false;
	}

	/// The errors and the document in canonical form.
	static void Describe(XmlDocument doc, Result<void, XmlParseError> result, String output)
	{
		if (result case .Err(let first) && doc.Errors.IsEmpty)
		{
			// Stopped before collecting (an encoding or input error)
			output.AppendF("stopped: {}\n", first);
			return;
		}
		for (let error in doc.Errors)
			output.AppendF("{}\n", error);
		doc.WriteCanonical(output);
	}

	static void Mutate(List<uint8> bytes, Random random)
	{
		int count = bytes.Count;
		switch (random.Next(4))
		{
		case 0:
			// Delete a few bytes
			if (count == 0)
				return;
			int at = random.Next(count);
			int length = Math.Min(1 + random.Next(8), count - at);
			bytes.RemoveRange(at, length);
		case 1:
			// Insert markup
			let text = sInserts[random.Next(sInserts.Count)];
			int at = random.Next(count + 1);
			bytes.Insert(at, Span<uint8>((uint8*)text.Ptr, text.Length));
		case 2:
			// Duplicate a slice somewhere else
			if (count == 0)
				return;
			int from = random.Next(count);
			int length = Math.Min(1 + random.Next(16), count - from);
			let slice = scope List<uint8>();
			slice.AddRange(Span<uint8>(bytes.Ptr + from, length));
			bytes.Insert(random.Next(count + 1), slice);
		default:
			// Replace a byte with markup's
			if (count == 0)
				return;
			let text = sInserts[random.Next(sInserts.Count)];
			bytes[random.Next(count)] = (uint8)text[0];
		}
	}
}
