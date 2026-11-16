#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct Address {
  int id;
  int set;
  char *name;
  char *email;
};

struct Database {
  int max_rows;
  int max_data;
  struct Address *rows;
};

struct Connection {
  FILE *file;
  struct Database *db;
};

void Database_close(struct Connection *conn) {
  if (conn) {
    if (conn->file)
      fclose(conn->file);
    if (conn->db) {
      if (conn->db->rows) {
        for (int i = 0; i < conn->db->max_rows; i++) {
          free(conn->db->rows[i].name);
          free(conn->db->rows[i].email);
        }
        free(conn->db->rows);
      }
      free(conn->db);
    }
    free(conn);
  }
}

void die(struct Connection *conn, const char *message) {
  if (errno) {
    perror(message);
  } else {
    printf("ERROR: %s\n", message);
  }

  if (conn != NULL) {
    Database_close(conn);
  }

  exit(1);
}

void Address_print(struct Address *addr) {
  printf("%d %s %s\n", addr->id, addr->name, addr->email);
}

void Database_load(struct Connection *conn) {
  if (fread(&conn->db->max_rows, sizeof(int), 1, conn->file) != 1)
    die(conn, "Failed to load max_rows.");
  if (fread(&conn->db->max_data, sizeof(int), 1, conn->file) != 1)
    die(conn, "Failed to load max_data");

  conn->db->rows = malloc(sizeof(struct Address) * conn->db->max_rows);
  if (!conn->db->rows)
    die(conn, "memory error");

  for (int i = 0; i < conn->db->max_rows; i++) {
    struct Address *cur = &conn->db->rows[i];
    fread(&cur->id, sizeof(int), 1, conn->file);
    fread(&cur->set, sizeof(int), 1, conn->file);

    cur->name = malloc(conn->db->max_data);
    cur->email = malloc(conn->db->max_data);
    fread(cur->name, conn->db->max_data, 1, conn->file);
    fread(cur->email, conn->db->max_data, 1, conn->file);
  }
}

struct Connection *Database_open(const char *filename, char mode) {
  struct Connection *conn = malloc(sizeof(struct Connection));
  if (!conn)
    die(conn, "Memory error");

  conn->db = malloc(sizeof(struct Database));
  if (!conn->db)
    die(conn, "Memory error");

  if (mode == 'c') {
    conn->file = fopen(filename, "w");
  } else {
    conn->file = fopen(filename, "r+");

    if (conn->file) {
      Database_load(conn);
    }
  }

  if (!conn->file)
    die(conn, "Failed to open the file");

  return conn;
}

void Database_write(struct Connection *conn) {
  rewind(conn->file);

  fwrite(&conn->db->max_rows, sizeof(int), 1, conn->file);
  fwrite(&conn->db->max_data, sizeof(int), 1, conn->file);

  for (int i = 0; i < conn->db->max_rows; i++) {
    struct Address *cur = &conn->db->rows[i];
    fwrite(&cur->id, sizeof(int), 1, conn->file);
    fwrite(&cur->set, sizeof(int), 1, conn->file);
    fwrite(cur->name, conn->db->max_data, 1, conn->file);
    fwrite(cur->email, conn->db->max_data, 1, conn->file);
  }

  fflush(conn->file);
}

void Database_find(struct Connection *conn, const char *keyword) {
  for (int i = 0; i < conn->db->max_rows; i++) {
    struct Address *cur = &conn->db->rows[i];
    if (cur->set &&
        (strstr(cur->name, keyword) || strstr(cur->email, keyword))) {
      Address_print(cur);
    }
  }
}

void Database_create(struct Connection *conn, int max_rows, int max_data) {
  conn->db->max_rows = max_rows;
  conn->db->max_data = max_data;

  conn->db->rows = malloc(sizeof(struct Address) * max_rows);
  if (!conn->db->rows)
    die(conn, "memory error:rows malloc failed");

  for (int i = 0; i < max_rows; i++) {
    // make a prototype to initialize it
    struct Address *addr = &conn->db->rows[i];
    // then just assign it
    addr->id = i;
    addr->set = 0;
    addr->name = malloc(max_data);
    addr->email = malloc(max_data);
    memset(addr->name, 0, max_data);
    memset(addr->email, 0, max_data);
  }
}

void Database_set(struct Connection *conn, int id, const char *name,
                  const char *email) {
  struct Address *addr = &conn->db->rows[id];
  if (addr->set)
    die(conn, "Already set, delete it first");

  addr->set = 1;
  // WARNING: bug, read the "How To Break It" and fix this
  int max_data = conn->db->max_data;
  char *res = strncpy(addr->name, name, max_data);
  // demonstrate the strncpy bug
  if (!res)
    die(conn, "Name copy failed");
  addr->name[conn->db->max_data - 1] = '\0';

  res = strncpy(addr->email, email, max_data);
  if (!res)
    die(conn, "Email copy failed");
  addr->email[conn->db->max_data - 1] = '\0';
}

void Database_get(struct Connection *conn, int id) {
  struct Address *addr = &conn->db->rows[id];

  if (addr->set) {
    Address_print(addr);
  } else {
    die(conn, "ID is not set");
  }
}

void Database_delete(struct Connection *conn, int id) {
  struct Address *addr = &conn->db->rows[id];
  addr->set = 0;
  memset(addr->name, 0, conn->db->max_data);
  memset(addr->email, 0, conn->db->max_data);
}

void Database_list(struct Connection *conn) {

  for (int i = 0; i < conn->db->max_rows; i++) {
    struct Address *cur = &conn->db->rows[i];

    if (cur->set) {
      Address_print(cur);
    }
  }
}

int main(int argc, char *argv[]) {
  if (argc < 3)
    die(NULL, "USAGE: ex17 <dbfile> <action> [action params]");

  char *filename = argv[1];
  char action = argv[2][0];
  struct Connection *conn = Database_open(filename, action);
  int id = 0;

  if (action != 'c')
    if (argc > 3)
      id = atoi(argv[3]);
  switch (action) {
  case 'c':
    if (argc != 5)
      die(conn, "usage: c <max_row> <max_data>");
    Database_create(conn, atoi(argv[3]), atoi(argv[4]));
    Database_write(conn);
    break;

  case 'g':
    if (argc != 4)
      die(conn, "Need an id to get");
    if (id >= conn->db->max_rows)
      die(conn, "there's not that many records");
    Database_get(conn, id);
    break;

  case 's':
    if (argc != 6)
      die(conn, "Need id, name, email to set");
    if (id >= conn->db->max_rows)
      die(conn, "there's not that many records");
    Database_set(conn, id, argv[4], argv[5]);
    Database_write(conn);
    break;

  case 'd':
    if (argc != 4)
      die(conn, "Need id to delete");
    if (id >= conn->db->max_rows)
      die(conn, "there's not that many records");

    Database_delete(conn, id);
    Database_write(conn);
    break;

  case 'l':
    Database_list(conn);
    break;

  case 'f':
    if (argc != 4)
      die(conn, "need a keyword to find");
    Database_find(conn, argv[3]);
    break;

  default:
    die(conn, "Invalid action: c=create, g=get, s=set, d=del, l=list");
  }

  Database_close(conn);
  return 0;
}
