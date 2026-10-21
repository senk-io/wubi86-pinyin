// 用 librime 驱动方案：逐行读取输入码，打印前 N 个候选及注释。
// 用法：rime_probe <shared_dir> <user_dir> <schema_id> [n]  （stdin 每行一个输入码）
// 输入行以 "!" 开头表示"选第 k 个候选上屏"，例如 "!2 ggtt"，用于测试用户词频。
// 以 "$ " 开头的行交给 shell 执行（用于模拟 wubi86d 写文件），其输出原样打印。
// 以 "@ " 开头的行只发送按键序列、不打印候选，例如 "@ {Control+Shift+R}"。
#include <rime_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void print_menu(RimeApi *api, RimeSessionId s, const char *code, int n) {
  RIME_STRUCT(RimeContext, ctx);
  if (!api->get_context(s, &ctx)) return;
  printf("%s:", code);
  for (int i = 0; i < ctx.menu.num_candidates && i < n; ++i) {
    RimeCandidate *c = &ctx.menu.candidates[i];
    printf(" %d.%s%s", i + 1, c->text, c->comment ? c->comment : "");
  }
  printf("\n");
  api->free_context(&ctx);
}

int main(int argc, char **argv) {
  if (argc < 4) return 2;
  int n = argc > 4 ? atoi(argv[4]) : 6;
  RimeApi *api = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.app_name = "rime.probe";
  traits.min_log_level = 2;
  api->setup(&traits);
  api->initialize(&traits);
  if (api->start_maintenance(True)) api->join_maintenance_thread();
  RimeSessionId s = api->create_session();
  if (!api->select_schema(s, argv[3])) { fprintf(stderr, "schema not found\n"); return 1; }
  char line[256];
  while (fgets(line, sizeof line, stdin)) {
    line[strcspn(line, "\r\n")] = 0;
    if (!*line) continue;
    if (line[0] == '$' && line[1] == ' ') {
      fflush(stdout);
      if (system(line + 2) != 0) fprintf(stderr, "command failed: %s\n", line + 2);
      continue;
    }
    if (line[0] == '@' && line[1] == ' ') {
      api->simulate_key_sequence(s, line + 2);
      continue;
    }
    int pick = 0;
    char *code = line;
    if (line[0] == '!') { pick = atoi(line + 1); code = strchr(line, ' ') + 1; }
    api->clear_composition(s);
    api->simulate_key_sequence(s, code);
    if (pick) {
      api->select_candidate_on_current_page(s, pick - 1);
      RIME_STRUCT(RimeCommit, commit);
      if (api->get_commit(s, &commit)) { printf("commit %s -> %s\n", code, commit.text); api->free_commit(&commit); }
    } else {
      print_menu(api, s, code, n);
    }
  }
  api->destroy_session(s);
  api->finalize();
  return 0;
}
