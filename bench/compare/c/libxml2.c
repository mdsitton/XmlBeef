// libxml2 benchmark: libxml2 <dom|reader> <file-or-dir> <min-samples>
//   dom    - xmlReadMemory into libxml2's tree (xmlDoc), freed with xmlFreeDoc. Options NOENT (internal
//            entities substituted, as an application reading SVG wants) and NONET; whitespace-only
//            text nodes are kept (no NOBLANKS). The walk for the check line is not timed.
//   reader - the xmlTextReader pull API over the same buffer and options: one run reads every node,
//            steps through every element's attributes and reads every text value (xmlTextReaderConstValue).
// Both detect the encoding (UTF-16 with a BOM included). Prints the check line (see run.sh) first.
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xmlreader.h>
#include "bench.h"

static const int OPTIONS = XML_PARSE_NOENT | XML_PARSE_NONET;

typedef struct
{
	inputs_t in;
	bool reader;
	check_t sum;
} ctx_t;

static void fail(const char *what)
{
	const xmlError *e = xmlGetLastError();
	fprintf(stderr, "parse error (%s): %s\n", what, e && e->message ? e->message : "?");
	exit(1);
}

// An attribute's value: its text children (entity references are substituted, NOENT)
static long content_chars(xmlNode *node)
{
	long n = 0;
	for (; node; node = node->next)
	{
		if (node->type == XML_TEXT_NODE)
			n += utf8_chars((const char *)node->content, strlen((const char *)node->content));
	}
	return n;
}

static void walk(xmlNode *node, check_t *c)
{
	for (; node; node = node->next)
	{
		if (node->type == XML_ELEMENT_NODE)
		{
			c->elements++;
			for (xmlAttr *a = node->properties; a; a = a->next)
			{
				c->attributes++;
				c->attr_chars += content_chars(a->children);
			}
			walk(node->children, c);
		}
		else if (node->type == XML_TEXT_NODE || node->type == XML_CDATA_SECTION_NODE)
			c->text_chars += utf8_chars((const char *)node->content, strlen((const char *)node->content));
	}
}

static check_t parse_dom(doc_t *d, bool check)
{
	check_t c = {0};
	xmlDoc *doc = xmlReadMemory(d->data, (int)d->size, NULL, NULL, OPTIONS);
	if (!doc)
		fail("dom");
	if (check)
		walk(xmlDocGetRootElement(doc), &c);
	xmlFreeDoc(doc);
	return c;
}

static long value_len(const xmlChar *v, bool check)
{
	size_t len = strlen((const char *)v);
	return check ? utf8_chars((const char *)v, len) : (long)len;
}

static check_t parse_reader(doc_t *d, bool check)
{
	check_t c = {0};
	xmlTextReader *r = xmlReaderForMemory(d->data, (int)d->size, NULL, NULL, OPTIONS);
	if (!r)
		fail("reader");
	int ret;
	while ((ret = xmlTextReaderRead(r)) == 1)
	{
		switch (xmlTextReaderNodeType(r))
		{
		case XML_READER_TYPE_ELEMENT:
			c.elements++;
			while (xmlTextReaderMoveToNextAttribute(r) == 1)
			{
				if (xmlTextReaderIsNamespaceDecl(r))
					continue;
				c.attributes++;
				c.attr_chars += value_len(xmlTextReaderConstValue(r), check);
			}
			break;
		case XML_READER_TYPE_TEXT:
		case XML_READER_TYPE_CDATA:
		case XML_READER_TYPE_WHITESPACE:
		case XML_READER_TYPE_SIGNIFICANT_WHITESPACE:
			c.text_chars += value_len(xmlTextReaderConstValue(r), check);
			break;
		default:
			break;
		}
	}
	xmlFreeTextReader(r);
	if (ret != 0)
		fail("reader");
	return c;
}

static check_t parse_all(ctx_t *x, bool check)
{
	check_t total = {0};
	for (int i = 0; i < x->in.count; i++)
	{
		check_t c = x->reader ? parse_reader(&x->in.docs[i], check) : parse_dom(&x->in.docs[i], check);
		total.elements += c.elements;
		total.attributes += c.attributes;
		total.attr_chars += c.attr_chars;
		total.text_chars += c.text_chars;
	}
	return total;
}

static void op(void *p)
{
	ctx_t *x = (ctx_t *)p;
	x->sum = parse_all(x, false);
}

int main(int argc, char **argv)
{
	if (argc < 4 || (strcmp(argv[1], "dom") != 0 && strcmp(argv[1], "reader") != 0))
	{
		fprintf(stderr, "usage: libxml2 <dom|reader> <file-or-dir> <min-samples>\n");
		return 2;
	}
	ctx_t x = {0};
	x.reader = strcmp(argv[1], "reader") == 0;
	read_inputs(&x.in, argv[2]);
	xmlInitParser();
	print_check(parse_all(&x, true));
	fflush(stdout);
	print_result(measure(op, &x, atoi(argv[3])), x.in.total);
	return 0;
}
