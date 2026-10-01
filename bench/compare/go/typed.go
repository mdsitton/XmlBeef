// The typed benchmark (../run-typed.sh): xml.Unmarshal into the model of osm.xml below, which matches
// XmlBeef's (XmlTester/src/Osm.bf), Rust's and .NET's: strings, numbers parsed, lists of child
// elements. Prints `check: N W R T D M S U P` (see Osm.bf), then the median time of one read.
package main

import (
	"encoding/xml"
	"fmt"
	"math"
	"os"
)

type osmTag struct {
	K string `xml:"k,attr"`
	V string `xml:"v,attr"`
}

type osmBounds struct {
	MinLat float64 `xml:"minlat,attr"`
	MinLon float64 `xml:"minlon,attr"`
	MaxLat float64 `xml:"maxlat,attr"`
	MaxLon float64 `xml:"maxlon,attr"`
}

type osmNode struct {
	ID        int64    `xml:"id,attr"`
	Version   int32    `xml:"version,attr"`
	Timestamp string   `xml:"timestamp,attr"`
	UID       int64    `xml:"uid,attr"`
	User      string   `xml:"user,attr"`
	Changeset int64    `xml:"changeset,attr"`
	Lat       float64  `xml:"lat,attr"`
	Lon       float64  `xml:"lon,attr"`
	Tags      []osmTag `xml:"tag"`
}

type osmNd struct {
	Ref int64 `xml:"ref,attr"`
}

type osmWay struct {
	ID        int64    `xml:"id,attr"`
	Version   int32    `xml:"version,attr"`
	Timestamp string   `xml:"timestamp,attr"`
	UID       int64    `xml:"uid,attr"`
	User      string   `xml:"user,attr"`
	Changeset int64    `xml:"changeset,attr"`
	Nds       []osmNd  `xml:"nd"`
	Tags      []osmTag `xml:"tag"`
}

type osmMember struct {
	Type string `xml:"type,attr"`
	Ref  int64  `xml:"ref,attr"`
	Role string `xml:"role,attr"`
}

type osmRelation struct {
	ID        int64       `xml:"id,attr"`
	Version   int32       `xml:"version,attr"`
	Timestamp string      `xml:"timestamp,attr"`
	UID       int64       `xml:"uid,attr"`
	User      string      `xml:"user,attr"`
	Changeset int64       `xml:"changeset,attr"`
	Members   []osmMember `xml:"member"`
	Tags      []osmTag    `xml:"tag"`
}

type osm struct {
	XMLName   xml.Name      `xml:"osm"`
	Version   string        `xml:"version,attr"`
	Generator string        `xml:"generator,attr"`
	Bounds    osmBounds     `xml:"bounds"`
	Nodes     []osmNode     `xml:"node"`
	Ways      []osmWay      `xml:"way"`
	Relations []osmRelation `xml:"relation"`
}

func (o *osm) check() string {
	var tags, nds, members, sum, users, coordinates int64
	for _, n := range o.Nodes {
		tags += int64(len(n.Tags))
		sum += n.ID
		users += int64(len(n.User))
		coordinates += int64(math.Round(n.Lat*1e7)) + int64(math.Round(n.Lon*1e7))
	}
	for _, w := range o.Ways {
		tags += int64(len(w.Tags))
		nds += int64(len(w.Nds))
		users += int64(len(w.User))
		for _, d := range w.Nds {
			sum += d.Ref
		}
	}
	for _, r := range o.Relations {
		tags += int64(len(r.Tags))
		members += int64(len(r.Members))
		users += int64(len(r.User))
		for _, m := range r.Members {
			sum += m.Ref
		}
	}
	return fmt.Sprintf("check: %d %d %d %d %d %d %d %d %d", len(o.Nodes), len(o.Ways), len(o.Relations), tags, nds, members, sum, users, coordinates)
}

func typedRun(data []byte, minSamples, total int) {
	var o osm
	if err := xml.Unmarshal(data, &o); err != nil {
		fmt.Fprintln(os.Stderr, "parse error:", err)
		os.Exit(1)
	}
	fmt.Println(o.check())
	median, n, converged := measure(minSamples, func() {
		var o osm
		if err := xml.Unmarshal(data, &o); err != nil {
			panic(err)
		}
	})
	ms := median / 1e6
	status := "capped"
	if converged {
		status = "converged"
	}
	fmt.Printf("%.3f ms/op %.1f MB/s (n=%d, %s)\n", ms, float64(total)/1048576.0/(ms/1000.0), n, status)
}
