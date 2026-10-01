// Shared measurement and input handling for the C and C++ harnesses. Every harness in bench/compare
// follows the same rule (see run.sh):
//   warm up for at least 1 s (at least one run), then time single runs until at least `min_samples`
//   were taken and at least 60% of them lie within ±10% of their median ("converged"), or 10 s of
//   measuring or 1000 samples have passed. The median sample is reported.
// An input is a file or a directory; a directory stands for every file under it (recursively, sorted),
// all read into memory first, and one run parses each of them once. MB/s is over their total size.
// (Measurement taken from KdlBeef's and TomlBeef's bench/compare/c/bench.h.)
#pragma once
#include <dirent.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#define BENCH_WARMUP_NS 1e9
#define BENCH_MAX_NS 10e9
#define BENCH_MAX_SAMPLES 1000
#define BENCH_WINDOW 0.10
#define BENCH_MAJORITY 0.6

static double bench_now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e9 + ts.tv_nsec;
}

static int bench_cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return (x > y) - (x < y);
}

typedef struct
{
	double median_ns;
	int samples;
	bool converged;
} measurement_t;

typedef void (*bench_op)(void *ctx);

static measurement_t measure(bench_op op, void *ctx, int min_samples)
{
	double warm = bench_now_ns();
	do
		op(ctx);
	while (bench_now_ns() - warm < BENCH_WARMUP_NS);

	static double samples[BENCH_MAX_SAMPLES], sorted[BENCH_MAX_SAMPLES];
	measurement_t m = {0};
	double start = bench_now_ns();
	int n = 0;
	while (n < BENCH_MAX_SAMPLES)
	{
		double t0 = bench_now_ns();
		op(ctx);
		samples[n++] = bench_now_ns() - t0;
		memcpy(sorted, samples, sizeof(double) * n);
		qsort(sorted, n, sizeof(double), bench_cmp);
		double median = (n % 2) ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
		m.median_ns = median;
		m.samples = n;
		if (n >= min_samples)
		{
			int within = 0;
			for (int i = 0; i < n; i++)
				within += samples[i] >= median * (1 - BENCH_WINDOW) && samples[i] <= median * (1 + BENCH_WINDOW);
			if (within >= BENCH_MAJORITY * n)
			{
				m.converged = true;
				break;
			}
		}
		if (bench_now_ns() - start >= BENCH_MAX_NS)
			break;
	}
	return m;
}

// Result line: "<ms> ms/op <MB/s> MB/s (n=<samples>, converged|capped)"
static void print_result(measurement_t m, long bytes)
{
	double ms = m.median_ns / 1e6;
	printf("%.3f ms/op %.1f MB/s (n=%d, %s)\n", ms, bytes / 1048576.0 / (ms / 1000.0), m.samples,
		m.converged ? "converged" : "capped");
}

// ---- Inputs ----

typedef struct
{
	char *data; // NUL-terminated
	long size;
} doc_t;

typedef struct
{
	doc_t *docs;
	int count, capacity;
	long total;
} inputs_t;

static void read_one(inputs_t *in, const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f)
	{
		fprintf(stderr, "cannot open %s\n", path);
		exit(2);
	}
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *data = (char *)malloc(size + 1);
	if (fread(data, 1, size, f) != (size_t)size)
		exit(2);
	data[size] = 0;
	fclose(f);
	if (in->count == in->capacity)
	{
		in->capacity = in->capacity ? in->capacity * 2 : 16;
		in->docs = (doc_t *)realloc(in->docs, sizeof(doc_t) * in->capacity);
	}
	in->docs[in->count].data = data;
	in->docs[in->count].size = size;
	in->count++;
	in->total += size;
}

static int bench_strcmp(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

// A file, or every file under a directory (recursively, in sorted order)
static void read_inputs(inputs_t *in, const char *path)
{
	struct stat st;
	if (stat(path, &st) != 0)
	{
		fprintf(stderr, "cannot open %s\n", path);
		exit(2);
	}
	if (!S_ISDIR(st.st_mode))
	{
		read_one(in, path);
		return;
	}
	DIR *dir = opendir(path);
	struct dirent *e;
	char **names = NULL;
	int n = 0, cap = 0;
	while ((e = readdir(dir)))
	{
		if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
			continue;
		if (n == cap)
		{
			cap = cap ? cap * 2 : 64;
			names = (char **)realloc(names, sizeof(char *) * cap);
		}
		size_t len = strlen(path) + strlen(e->d_name) + 2;
		names[n] = (char *)malloc(len);
		snprintf(names[n], len, "%s/%s", path, e->d_name);
		n++;
	}
	closedir(dir);
	qsort(names, n, sizeof(char *), bench_strcmp);
	for (int i = 0; i < n; i++)
	{
		read_inputs(in, names[i]);
		free(names[i]);
	}
	free(names);
}

// Whether any document starts with a UTF-16 byte order mark (for harnesses of UTF-8-only libraries,
// which then exit 3: n/a)
static bool any_utf16(const inputs_t *in)
{
	for (int i = 0; i < in->count; i++)
	{
		const unsigned char *d = (const unsigned char *)in->docs[i].data;
		if (in->docs[i].size >= 2 && ((d[0] == 0xFF && d[1] == 0xFE) || (d[0] == 0xFE && d[1] == 0xFF)))
			return true;
	}
	return false;
}

// ---- The check line ----

// Unicode code points in UTF-8 text: every byte that is not a continuation byte
static long utf8_chars(const char *s, size_t len)
{
	long n = 0;
	for (size_t i = 0; i < len; i++)
		n += ((unsigned char)s[i] & 0xC0) != 0x80;
	return n;
}

// Code points in UTF-16 text: every unit that is not a low surrogate
static long utf16_chars(const uint16_t *s, size_t len)
{
	long n = 0;
	for (size_t i = 0; i < len; i++)
		n += (s[i] & 0xFC00) != 0xDC00;
	return n;
}

// Whether an attribute name is a namespace declaration (xmlns or xmlns:*), which the check excludes
static bool is_xmlns(const char *name)
{
	return strncmp(name, "xmlns", 5) == 0 && (name[5] == 0 || name[5] == ':');
}

typedef struct
{
	long elements, attributes, attr_chars, text_chars;
} check_t;

// "check: <elements> <attributes> <attribute-value chars> <text chars>" (see run.sh); a negative
// field prints as "-" (not computed by that library)
static void print_check(check_t c)
{
	printf("check:");
	long f[4] = {c.elements, c.attributes, c.attr_chars, c.text_chars};
	for (int i = 0; i < 4; i++)
	{
		if (f[i] < 0)
			printf(" -");
		else
			printf(" %ld", f[i]);
	}
	printf("\n");
}
