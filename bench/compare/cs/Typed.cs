// The typed benchmark (../run-typed.sh): System.Xml.Serialization.XmlSerializer.Deserialize into the
// model of osm.xml below, which matches XmlBeef's (XmlTester/src/Osm.bf), Rust's and Go's: strings,
// numbers parsed, lists of child elements. The serializer is created once, outside the timing (its
// first use generates code). Prints `check: N W R T D M S U P` (see Osm.bf), then the median time of
// one read from a MemoryStream over the bytes.
using System.Text;
using System.Xml.Serialization;

public class OsmTag
{
	[XmlAttribute("k")] public string K = "";
	[XmlAttribute("v")] public string V = "";
}

public class OsmBounds
{
	[XmlAttribute("minlat")] public double MinLat;
	[XmlAttribute("minlon")] public double MinLon;
	[XmlAttribute("maxlat")] public double MaxLat;
	[XmlAttribute("maxlon")] public double MaxLon;
}

public class OsmElementBase
{
	[XmlAttribute("id")] public long Id;
	[XmlAttribute("version")] public int Version;
	[XmlAttribute("timestamp")] public string Timestamp = "";
	[XmlAttribute("uid")] public long Uid;
	[XmlAttribute("user")] public string User = "";
	[XmlAttribute("changeset")] public long Changeset;
}

public class OsmNode : OsmElementBase
{
	[XmlAttribute("lat")] public double Lat;
	[XmlAttribute("lon")] public double Lon;
	[XmlElement("tag")] public List<OsmTag> Tags = new();
}

public class OsmNd
{
	[XmlAttribute("ref")] public long Ref;
}

public class OsmWay : OsmElementBase
{
	[XmlElement("nd")] public List<OsmNd> Nds = new();
	[XmlElement("tag")] public List<OsmTag> Tags = new();
}

public class OsmMember
{
	[XmlAttribute("type")] public string Type = "";
	[XmlAttribute("ref")] public long Ref;
	[XmlAttribute("role")] public string Role = "";
}

public class OsmRelation : OsmElementBase
{
	[XmlElement("member")] public List<OsmMember> Members = new();
	[XmlElement("tag")] public List<OsmTag> Tags = new();
}

[XmlRoot("osm")]
public class Osm
{
	[XmlAttribute("version")] public string Version = "";
	[XmlAttribute("generator")] public string Generator = "";
	[XmlElement("bounds")] public OsmBounds Bounds = new();
	[XmlElement("node")] public List<OsmNode> Nodes = new();
	[XmlElement("way")] public List<OsmWay> Ways = new();
	[XmlElement("relation")] public List<OsmRelation> Relations = new();

	public string Check()
	{
		long tags = 0, nds = 0, members = 0, sum = 0, users = 0, coordinates = 0;
		foreach (var n in Nodes)
		{
			tags += n.Tags.Count;
			sum += n.Id;
			users += Encoding.UTF8.GetByteCount(n.User);
			coordinates += (long)Math.Round(n.Lat * 1e7) + (long)Math.Round(n.Lon * 1e7);
		}
		foreach (var w in Ways)
		{
			tags += w.Tags.Count;
			nds += w.Nds.Count;
			users += Encoding.UTF8.GetByteCount(w.User);
			foreach (var d in w.Nds)
				sum += d.Ref;
		}
		foreach (var r in Relations)
		{
			tags += r.Tags.Count;
			members += r.Members.Count;
			users += Encoding.UTF8.GetByteCount(r.User);
			foreach (var m in r.Members)
				sum += m.Ref;
		}
		return $"check: {Nodes.Count} {Ways.Count} {Relations.Count} {tags} {nds} {members} {sum} {users} {coordinates}";
	}
}

public static class Typed
{
	public static int Run(byte[] data, int minSamples, long total, Func<int, Action, (double MedianNs, int Samples, bool Converged)> measure)
	{
		var serializer = new XmlSerializer(typeof(Osm));
		Osm osm;
		try
		{
			osm = (Osm)serializer.Deserialize(new MemoryStream(data))!;
		}
		catch (Exception e)
		{
			Console.Error.WriteLine($"parse error: {e.Message}");
			return 1;
		}
		Console.WriteLine(osm.Check());
		var result = measure(minSamples, () => GC.KeepAlive(serializer.Deserialize(new MemoryStream(data))));
		double ms = result.MedianNs / 1e6;
		Console.WriteLine($"{ms:F3} ms/op {total / 1048576.0 / (ms / 1000.0):F1} MB/s (n={result.Samples}, {(result.Converged ? "converged" : "capped")})");
		return 0;
	}
}
