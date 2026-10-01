// The typed benchmark (../run-typed.sh): quick_xml::de::from_str into the model of osm.xml below, which
// matches XmlBeef's (XmlTester/src/Osm.bf), Go's and .NET's: owned Strings, numbers parsed, lists of
// child elements. Prints `check: N W R T D M S U P` (see Osm.bf), then the median time of one read.
use serde::Deserialize;

#[derive(Deserialize)]
struct Osm {
    #[serde(rename = "@version")]
    _version: String,
    #[serde(rename = "@generator")]
    _generator: String,
    #[serde(rename = "bounds")]
    _bounds: Bounds,
    #[serde(rename = "node", default)]
    nodes: Vec<Node>,
    #[serde(rename = "way", default)]
    ways: Vec<Way>,
    #[serde(rename = "relation", default)]
    relations: Vec<Relation>,
}

#[derive(Deserialize)]
struct Bounds {
    #[serde(rename = "@minlat")]
    _minlat: f64,
    #[serde(rename = "@minlon")]
    _minlon: f64,
    #[serde(rename = "@maxlat")]
    _maxlat: f64,
    #[serde(rename = "@maxlon")]
    _maxlon: f64,
}

#[derive(Deserialize)]
struct Tag {
    #[serde(rename = "@k")]
    _k: String,
    #[serde(rename = "@v")]
    _v: String,
}

#[derive(Deserialize)]
struct Node {
    #[serde(rename = "@id")]
    id: i64,
    #[serde(rename = "@version")]
    _version: i32,
    #[serde(rename = "@timestamp")]
    _timestamp: String,
    #[serde(rename = "@uid")]
    _uid: i64,
    #[serde(rename = "@user")]
    user: String,
    #[serde(rename = "@changeset")]
    _changeset: i64,
    #[serde(rename = "@lat")]
    lat: f64,
    #[serde(rename = "@lon")]
    lon: f64,
    #[serde(rename = "tag", default)]
    tags: Vec<Tag>,
}

#[derive(Deserialize)]
struct Nd {
    #[serde(rename = "@ref")]
    target: i64,
}

#[derive(Deserialize)]
struct Way {
    #[serde(rename = "@id")]
    _id: i64,
    #[serde(rename = "@version")]
    _version: i32,
    #[serde(rename = "@timestamp")]
    _timestamp: String,
    #[serde(rename = "@uid")]
    _uid: i64,
    #[serde(rename = "@user")]
    user: String,
    #[serde(rename = "@changeset")]
    _changeset: i64,
    #[serde(rename = "nd", default)]
    nds: Vec<Nd>,
    #[serde(rename = "tag", default)]
    tags: Vec<Tag>,
}

#[derive(Deserialize)]
struct Member {
    #[serde(rename = "@type")]
    _kind: String,
    #[serde(rename = "@ref")]
    target: i64,
    #[serde(rename = "@role")]
    _role: String,
}

#[derive(Deserialize)]
struct Relation {
    #[serde(rename = "@id")]
    _id: i64,
    #[serde(rename = "@version")]
    _version: i32,
    #[serde(rename = "@timestamp")]
    _timestamp: String,
    #[serde(rename = "@uid")]
    _uid: i64,
    #[serde(rename = "@user")]
    user: String,
    #[serde(rename = "@changeset")]
    _changeset: i64,
    #[serde(rename = "member", default)]
    members: Vec<Member>,
    #[serde(rename = "tag", default)]
    tags: Vec<Tag>,
}

fn check(osm: &Osm) -> String {
    let (mut tags, mut nds, mut members, mut sum, mut users, mut coordinates) = (0i64, 0i64, 0i64, 0i64, 0i64, 0i64);
    for n in &osm.nodes {
        tags += n.tags.len() as i64;
        sum += n.id;
        users += n.user.len() as i64;
        coordinates += (n.lat * 1e7).round() as i64 + (n.lon * 1e7).round() as i64;
    }
    for w in &osm.ways {
        tags += w.tags.len() as i64;
        nds += w.nds.len() as i64;
        users += w.user.len() as i64;
        sum += w.nds.iter().map(|d| d.target).sum::<i64>();
    }
    for r in &osm.relations {
        tags += r.tags.len() as i64;
        members += r.members.len() as i64;
        users += r.user.len() as i64;
        sum += r.members.iter().map(|m| m.target).sum::<i64>();
    }
    format!("check: {} {} {} {} {} {} {} {} {}", osm.nodes.len(), osm.ways.len(), osm.relations.len(), tags, nds, members, sum, users, coordinates)
}

pub fn run(text: &str, min_samples: usize, total: usize) {
    let osm: Osm = quick_xml::de::from_str(text).unwrap_or_else(|e| {
        eprintln!("parse error: {e}");
        std::process::exit(1)
    });
    println!("{}", check(&osm));
    let (median, n, converged) = crate::measure(min_samples, || {
        let osm: Osm = quick_xml::de::from_str(text).unwrap();
        std::hint::black_box(osm);
    });
    let ms = median / 1e6;
    println!("{:.3} ms/op {:.1} MB/s (n={}, {})", ms, total as f64 / 1048576.0 / (ms / 1000.0), n,
        if converged { "converged" } else { "capped" });
}
