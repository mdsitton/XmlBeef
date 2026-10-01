using System;
using System.Collections;
using XmlBeef;

namespace XmlTester;

/// The typed benchmark's model of bench/compare/inputs/osm.xml (`XmlTester -bench typed`), mapped as the
/// Rust (quick-xml + serde), Go (encoding/xml) and .NET (XmlSerializer) harnesses map it.
[XmlObject(Name = "osm")]
class Osm
{
	public String version ~ delete _;
	public String generator ~ delete _;
	public OsmBounds bounds ~ delete _;
	public List<OsmNode> nodes ~ DeleteContainerAndItems!(_);
	public List<OsmWay> ways ~ DeleteContainerAndItems!(_);
	public List<OsmRelation> relations ~ DeleteContainerAndItems!(_);

	/// `check: N W R T D M S U P`: nodes, ways, relations, tags, way node references, relation members,
	/// the sum of node ids and references, the UTF-8 bytes of the user names, and the sum of the
	/// coordinates in units of 1e-7 degrees.
	public void AppendCheck(String output)
	{
		int64 tags = 0;
		int64 nds = 0;
		int64 members = 0;
		int64 sum = 0;
		int64 users = 0;
		int64 coordinates = 0;
		for (let node in nodes)
		{
			tags += node.tags.Count;
			sum += node.id;
			users += node.user.Length;
			coordinates += (int64)Math.Round(node.lat * 1e7) + (int64)Math.Round(node.lon * 1e7);
		}
		for (let way in ways)
		{
			tags += way.tags.Count;
			nds += way.nds.Count;
			users += way.user.Length;
			for (let nd in way.nds)
				sum += nd.target;
		}
		for (let relation in relations)
		{
			tags += relation.tags.Count;
			members += relation.members.Count;
			users += relation.user.Length;
			for (let member in relation.members)
				sum += member.target;
		}
		output.AppendF("check: {} {} {} {} {} {} {} {} {}", nodes.Count, ways.Count, relations.Count, tags, nds, members, sum, users, coordinates);
	}
}

[XmlObject(Name = "bounds")]
class OsmBounds
{
	public double minlat;
	public double minlon;
	public double maxlat;
	public double maxlon;
}

[XmlObject(Name = "tag")]
class OsmTag
{
	public String k ~ delete _;
	public String v ~ delete _;
}

/// The attributes nodes, ways and relations share.
[XmlObject]
abstract class OsmElement
{
	public int64 id;
	public int32 version;
	public String timestamp ~ delete _;
	public int64 uid;
	public String user ~ delete _;
	public int64 changeset;
	public List<OsmTag> tags = new .() ~ DeleteContainerAndItems!(_);
}

[XmlObject(Name = "node")]
class OsmNode : OsmElement
{
	public double lat;
	public double lon;
}

[XmlObject(Name = "nd")]
struct OsmNd
{
	[XmlName("ref")] public int64 target;
}

[XmlObject(Name = "way")]
class OsmWay : OsmElement
{
	public List<OsmNd> nds = new .() ~ delete _;
}

[XmlObject(Name = "member")]
class OsmMember
{
	public String type ~ delete _;
	[XmlName("ref")] public int64 target;
	public String role ~ delete _;
}

[XmlObject(Name = "relation")]
class OsmRelation : OsmElement
{
	public List<OsmMember> members = new .() ~ DeleteContainerAndItems!(_);
}
