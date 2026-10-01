// Go XML benchmark: xmlbench <encoding/xml|etree|xmlquery> <file-or-dir> <min-samples>
//
//	encoding/xml - the standard library: xml.Decoder.Token loop over every token (namespace-
//	               resolved names, entity and character references decoded, CDATA as CharData).
//	               It reads no DTD, so entities declared there are errors (Strict).
//	etree        - github.com/beevik/etree: Document.ReadFromBytes into its tree (built on
//	               encoding/xml; whitespace-only text kept).
//	xmlquery     - github.com/antchfx/xmlquery: Parse into its tree (built on encoding/xml, with
//	               golang.org/x/net/html/charset as its CharsetReader).
//
// An input is a file or a directory (every file under it, sorted; one run parses each once). The
// check line (see ../run.sh) is printed first; attribute lists include namespace declarations, which
// the check leaves out. encoding/xml and etree have no UTF-16 support without a CharsetReader and exit
// 3 (n/a) on a UTF-16 input. Timings follow the shared rule (see measure).
package main

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/antchfx/xmlquery"
	"github.com/beevik/etree"
)

// measure warms up for at least 1 s (at least one run), then times single runs until at least
// minSamples were taken and at least 60% lie within ±10% of their median ("converged"), or 10 s of
// measuring or 1000 samples have passed. Returns the median sample in ns.
func measure(minSamples int, op func()) (median float64, n int, converged bool) {
	warm := time.Now()
	for {
		op()
		if time.Since(warm) >= time.Second {
			break
		}
	}
	start := time.Now()
	var samples []float64
	for {
		t0 := time.Now()
		op()
		samples = append(samples, float64(time.Since(t0).Nanoseconds()))
		sorted := append([]float64(nil), samples...)
		sort.Float64s(sorted)
		n = len(sorted)
		if n%2 == 1 {
			median = sorted[n/2]
		} else {
			median = (sorted[n/2-1] + sorted[n/2]) / 2
		}
		if n >= minSamples {
			within := 0
			for _, s := range samples {
				if s >= median*0.9 && s <= median*1.1 {
					within++
				}
			}
			if float64(within) >= 0.6*float64(n) {
				return median, n, true
			}
		}
		if n >= 1000 || time.Since(start) >= 10*time.Second {
			return median, n, false
		}
	}
}

// check: elements, attributes (without namespace declarations), attribute value chars, text chars
type check struct{ elements, attributes, attrChars, textChars int }

func (c *check) add(o check) {
	c.elements += o.elements
	c.attributes += o.attributes
	c.attrChars += o.attrChars
	c.textChars += o.textChars
}

// length in code points when checking, in bytes when timing (the timed runs only need to touch it)
func length(s []byte, exact bool) int {
	if exact {
		return utf8.RuneCount(s)
	}
	return len(s)
}

func isXmlns(space, local string) bool {
	return space == "xmlns" || (space == "" && local == "xmlns")
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "parse error:", err)
	os.Exit(1)
}

func stdlib(data []byte, exact bool) check {
	var c check
	d := xml.NewDecoder(bytes.NewReader(data))
	depth := 0
	for {
		tok, err := d.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			fail(err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			c.elements++
			depth++
			for _, a := range t.Attr {
				if isXmlns(a.Name.Space, a.Name.Local) {
					continue
				}
				c.attributes++
				if exact {
					c.attrChars += utf8.RuneCountInString(a.Value)
				} else {
					c.attrChars += len(a.Value)
				}
			}
		case xml.EndElement:
			depth--
		case xml.CharData:
			if depth > 0 {
				c.textChars += length(t, exact)
			}
		}
	}
	return c
}

func etreeParse(data []byte) *etree.Document {
	doc := etree.NewDocument()
	if err := doc.ReadFromBytes(data); err != nil {
		fail(err)
	}
	return doc
}

func etreeCheck(e *etree.Element, c *check) {
	c.elements++
	for _, a := range e.Attr {
		if isXmlns(a.Space, a.Key) {
			continue
		}
		c.attributes++
		c.attrChars += utf8.RuneCountInString(a.Value)
	}
	for _, t := range e.Child {
		switch n := t.(type) {
		case *etree.Element:
			etreeCheck(n, c)
		case *etree.CharData:
			c.textChars += utf8.RuneCountInString(n.Data)
		}
	}
}

func xmlqueryParse(data []byte) *xmlquery.Node {
	doc, err := xmlquery.Parse(bytes.NewReader(data))
	if err != nil {
		fail(err)
	}
	return doc
}

func xmlqueryCheck(n *xmlquery.Node, c *check, inside bool) {
	for child := n.FirstChild; child != nil; child = child.NextSibling {
		switch child.Type {
		case xmlquery.ElementNode:
			c.elements++
			for _, a := range child.Attr {
				if isXmlns(a.Name.Space, a.Name.Local) {
					continue
				}
				c.attributes++
				c.attrChars += utf8.RuneCountInString(a.Value)
			}
			xmlqueryCheck(child, c, true)
		case xmlquery.TextNode, xmlquery.CharDataNode:
			if inside {
				c.textChars += utf8.RuneCountInString(child.Data)
			}
		}
	}
}

func collect(path string, files *[]string) {
	info, err := os.Stat(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if !info.IsDir() {
		*files = append(*files, path)
		return
	}
	entries, _ := os.ReadDir(path)
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		collect(filepath.Join(path, name), files)
	}
}

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: xmlbench <encoding/xml|etree|xmlquery> <file-or-dir> <min-samples>")
		os.Exit(2)
	}
	lib := os.Args[1]
	minSamples, _ := strconv.Atoi(os.Args[3])
	var files []string
	collect(os.Args[2], &files)
	var docs [][]byte
	total, utf16 := 0, false
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(2)
		}
		docs = append(docs, data)
		total += len(data)
		utf16 = utf16 || bytes.HasPrefix(data, []byte{0xFF, 0xFE}) || bytes.HasPrefix(data, []byte{0xFE, 0xFF})
	}
	if utf16 && lib != "xmlquery" {
		fmt.Fprintln(os.Stderr, lib, "has no UTF-16 support without a CharsetReader")
		os.Exit(3)
	}

	if lib == "encoding/xml-unmarshal" {
		typedRun(docs[0], minSamples, total)
		return
	}
	var c check
	var op func()
	switch lib {
	case "encoding/xml":
		for _, d := range docs {
			c.add(stdlib(d, true))
		}
		op = func() {
			for _, d := range docs {
				stdlib(d, false)
			}
		}
	case "etree":
		for _, d := range docs {
			etreeCheck(etreeParse(d).Root(), &c)
		}
		op = func() {
			for _, d := range docs {
				etreeParse(d)
			}
		}
	case "xmlquery":
		for _, d := range docs {
			xmlqueryCheck(xmlqueryParse(d), &c, false)
		}
		op = func() {
			for _, d := range docs {
				xmlqueryParse(d)
			}
		}
	default:
		fmt.Fprintln(os.Stderr, "unknown library", lib)
		os.Exit(2)
	}
	fmt.Printf("check: %d %d %d %d\n", c.elements, c.attributes, c.attrChars, c.textChars)
	median, n, converged := measure(minSamples, op)
	ms := median / 1e6
	status := "capped"
	if converged {
		status = "converged"
	}
	fmt.Printf("%.3f ms/op %.1f MB/s (n=%d, %s)\n", ms, float64(total)/1048576.0/(ms/1000.0), n, status)
}
