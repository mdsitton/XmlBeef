# Typed reading compared

Produced by run-typed.sh on 2026-10-02 (AMD Ryzen 9 5900X 12-Core Processor, Linux x86-64, single thread). MB/s of osm.xml (15.0 MB) read into the same OpenStreetMap model, higher is better.

### Typed reading (MB/s)

| input | XmlBeef | quick-xml + serde | encoding/xml Unmarshal | XmlSerializer (.NET) |
|---|---:|---:|---:|---:|
| osm | 139.7 | 90.4 | 23.2 | 69.0 |

Load average 13.24 at the start, 9.53 at the end; 3 to 9 processes per cell, until 3 agree within ±5% (~: they did not). Reference: check: 55000 7000 1000 67227 91546 10408 190166011548 822875 28266858793498
