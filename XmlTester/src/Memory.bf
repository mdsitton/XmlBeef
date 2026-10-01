using System;
using System.Collections;
using XmlBeef;

namespace XmlTester;

/// `XmlTester -memory <large-file> <small-file>`: what a document holds (XmlDocument.MemoryUsage)
/// through the edit sequences of review P04 (values replaced over and over, attributes edited on
/// elements in turn, nodes removed), after Compact, and across a large read followed by a small one,
/// with Clear and Clear(true). Figures are the document's own accounting, not the process's resident
/// memory, which the allocator decides.
static class Memory
{
	public static int Run(StringView large, StringView small)
	{
		Console.WriteLine("step                              node slots/live   attr slots/live   text reserved/filled/live   total KiB");
		for (let mode in XmlMetadataMode[](.None, .PreserveStyle))
		{
			let doc = scope XmlDocument();
			var config = XmlReadConfig();
			config.MetadataMode = mode;
			if (doc.ReadFile(large, config) case .Err(let error))
			{
				Console.Error.WriteLine($"{error}");
				return 2;
			}
			Console.WriteLine($"-- {large} ({mode})");
			Print("read", doc);
			let elements = scope List<XmlNode>();
			for (let element in doc.Root.Descendants)
				elements.Add(element);
			// Every text value replaced ten times
			for (int round < 10)
			{
				for (let element in elements)
				{
					if (element.FirstChild.IsValid && element.FirstChild.Kind == .Text)
						element.FirstChild.SetValue(scope $"replaced {round}");
				}
			}
			Print("text replaced x10", doc);
			// An attribute added on every element in turn, five times: each append moves the element's
			// attributes to the table's end
			for (int round < 5)
			{
				for (let element in elements)
					element.SetAttribute(scope $"added{round}", "v");
			}
			Print("attributes added x5", doc);
			// Every other child element of the root removed, with what is under it
			let children = scope List<XmlNode>();
			for (let child in doc.Root.Children)
			{
				if (child.Kind == .Element)
					children.Add(child);
			}
			for (int i = 0; i < children.Count; i += 2)
				children[i].Remove();
			Print("half the root's children removed", doc);
			doc.Compact();
			Print("Compact", doc);
		}
		let doc = scope XmlDocument();
		if (doc.ReadFile(large) case .Err(let largeError))
		{
			Console.Error.WriteLine($"{largeError}");
			return 2;
		}
		Console.WriteLine($"-- {large}, then {small}");
		Print("large read", doc);
		if (doc.ReadFile(small) case .Err(let smallError))
		{
			Console.Error.WriteLine($"{smallError}");
			return 2;
		}
		Print("small read (memory kept)", doc);
		doc.Clear(true);
		Print("Clear(true)", doc);
		if (doc.ReadFile(small) case .Err(let againError))
		{
			Console.Error.WriteLine($"{againError}");
			return 2;
		}
		Print("small read again", doc);
		return 0;
	}

	static void Print(StringView step, XmlDocument doc)
	{
		let usage = doc.MemoryUsage;
		Console.WriteLine("{0,-33} {1,9}/{2,-9} {3,9}/{4,-9} {5,9}/{6,9}/{7,-9} {8,9}", step, usage.mNodeSlots, usage.mNodes,
			usage.mAttributeSlots, usage.mAttributes, usage.mTextReserved, usage.mTextFilled, usage.mTextLive, usage.mTotalReserved / 1024);
	}
}
