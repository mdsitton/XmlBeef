// pugixml benchmark: pugixml <default|ws> <file-or-dir> <min-samples>
//   default - xml_document::load_buffer with pugi::parse_default, the speed reference: pugixml drops
//             whitespace-only text there (no parse_ws_pcdata), so its text figure is not compared
//             ("-"). It does not read DTD entity declarations and leaves their references as text.
//   ws      - parse_default | parse_ws_pcdata: keeps whitespace-only text nodes like every other
//             harness, so the whole check line is compared.
// encoding_auto (UTF-16 by its BOM is converted). The document is destroyed within the timed run; the
// walk for the check line is not timed. Prints the check line (see run.sh) first.
#include <pugixml.hpp>
#include <string>
#include "../c/bench.h"

struct Ctx
{
	inputs_t in;
	unsigned options;
};

static void walk(pugi::xml_node node, check_t& c)
{
	for (pugi::xml_node child = node.first_child(); child; child = child.next_sibling())
	{
		switch (child.type())
		{
		case pugi::node_element:
			c.elements++;
			for (pugi::xml_attribute a = child.first_attribute(); a; a = a.next_attribute())
			{
				if (is_xmlns(a.name()))
					continue;
				c.attributes++;
				c.attr_chars += utf8_chars(a.value(), strlen(a.value()));
			}
			walk(child, c);
			break;
		case pugi::node_pcdata:
		case pugi::node_cdata:
			c.text_chars += utf8_chars(child.value(), strlen(child.value()));
			break;
		default:
			break;
		}
	}
}

static check_t parse_all(Ctx& x, bool check)
{
	check_t total = {0, 0, 0, 0};
	for (int i = 0; i < x.in.count; i++)
	{
		pugi::xml_document doc;
		pugi::xml_parse_result r = doc.load_buffer(x.in.docs[i].data, x.in.docs[i].size, x.options, pugi::encoding_auto);
		if (!r)
		{
			std::fprintf(stderr, "parse error: %s at offset %ld\n", r.description(), (long)r.offset);
			std::exit(1);
		}
		if (check)
		{
			// Only children of the root element: whitespace outside it is not character data
			walk(doc.document_element(), total);
			total.elements++;
			for (pugi::xml_attribute a = doc.document_element().first_attribute(); a; a = a.next_attribute())
			{
				if (!is_xmlns(a.name()))
				{
					total.attributes++;
					total.attr_chars += utf8_chars(a.value(), strlen(a.value()));
				}
			}
		}
	}
	return total;
}

int main(int argc, char** argv)
{
	if (argc < 4)
	{
		std::fprintf(stderr, "usage: pugixml <default|ws> <file-or-dir> <min-samples>\n");
		return 2;
	}
	static Ctx x;
	bool ws = std::string(argv[1]) == "ws";
	x.options = pugi::parse_default | (ws ? pugi::parse_ws_pcdata : 0);
	read_inputs(&x.in, argv[2]);
	check_t c = parse_all(x, true);
	if (!ws)
		c.text_chars = -1;
	print_check(c);
	std::fflush(stdout);
	print_result(measure([](void* p) { parse_all(*static_cast<Ctx*>(p), false); }, &x, std::atoi(argv[3])), x.in.total);
	return 0;
}
