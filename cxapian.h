#ifndef XAPIAN_H
#define XAPIAN_H

typedef struct _xapian_database xapian_database_t;

extern "C" {

  xapian_database_t *
  xapian_writable_db_new (const char *filename, int action,
                          const char **error);

  void xapian_writable_db_add_document(xapian_database_t *database, void *document);

  void* xapian_document_new ();

  void xapian_document_set_data (void *document, const char* data);

  void xapian_document_add_posting (void *doc, const char* posting,
                                    int pos);

  xapian_database_t *
  xapian_database_new (const char *cFilename, const char **errorStr);

  void *xapian_enquire_new (xapian_database_t *database);

  void *xapian_query_new (const char* term);

  void *xapian_query_combine (int op, void *vqa, void *vqb);

  const char *xapian_query_describe (void *vqa);
}

#endif
