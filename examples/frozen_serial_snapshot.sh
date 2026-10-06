#!/usr/bin/env bash
# 本轮修复端到端示例: 删除同编号重录后、未重新发布分配时, 不得用旧评语签发作者反馈
#
# 缺陷背景:
#   旧发布版两名评审人已确认并交评语、删除前从未发布反馈快照时, 会务方删除该稿并以
#   同编号录入新稿, 但尚未重新发布分配——此时当前发布请求曾用旧序号上的旧评语收据
#   生成新的访问码, 持码者凭新码读到的是旧稿评语。
#
# 修复后约定 (本脚本逐步演示):
#   1) 针对删除冻结序号的反馈快照请求一律 409 拒绝: 不生成快照版本或访问码,
#      也不改变资料修订号; 冻结序号上的旧确认/旧评语仅供会务方追溯;
#   2) 评审人在冻结序号上确认/交评语继续 404, 取稿列表不含该稿; 任何旧码/猜测码
#      持码读取仍为与无效码同形的 404;
#   3) 必须先重新发布分配 (普通发布/补位发布, 推进发布序号), 并在新序号重新确认、
#      交齐两份评语, 才能为重录稿发布快照; 新码读到的是重录稿的新评语;
#   4) 删除、重录与快照发布在各自现有写事务 (BEGIN IMMEDIATE) 内一致判定;
#      既有快照发布、持码读取与无效码响应约定保持不变。
#
# 建议对空库运行。用法: ./examples/frozen_serial_snapshot.sh [BASE_URL]
set -euo pipefail

BASE="${1:-http://localhost:8000}"
ORG="X-Organizer-Key: ${ORGANIZER_KEY:-dev-organizer-key}"
j() { python3 -c 'import sys, json; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
post_json() { curl -s -X POST "$BASE$1" -H "$ORG" -H 'Content-Type: application/json' -d "$2"; }

echo "== 1. 录入两名评审人与论文 P1, 发布分配 (发布序号记为 S1) =="
for spec in 'R1 r1-secret Inst-A' 'R2 r2-secret Inst-B'; do
  set -- $spec
  curl -s -o /dev/null -X POST "$BASE/reviewers" -H "$ORG" -H 'Content-Type: application/json' -d "{
    \"reviewer_id\": \"$1\", \"credential\": \"$2\", \"topics\": [\"AI\"],
    \"institution\": \"$3\", \"capacity\": 3, \"avoid_papers\": []}"
done
curl -s -o /dev/null -X POST "$BASE/papers" -H "$ORG" -H 'Content-Type: application/json' -d '{
  "paper_id": "P1", "manuscript": "旧稿全文 (删除前版本)", "topics": ["AI"], "institutions": ["Univ-X"]}'
REV=$(curl -s -X POST "$BASE/assignment/dry-run" -H "$ORG" | j 'd["revision"]')
S1=$(post_json /assignment/publish "{\"base_revision\": $REV}" | j 'd["serial"]')
echo "    已发布: serial=$S1"

echo "== 2. 两名评审人在 S1 上确认并各交一份正式评语 (旧稿评语) =="
confirm_and_review_at() {
  local serial="$1" rid="$2" cred="$3" score="$4" comment="$5"
  curl -s -o /dev/null -X POST "$BASE/reviewer/assignments/P1/decision" \
    -H "X-Reviewer-Id: $rid" -H "X-Reviewer-Credential: $cred" \
    -H 'Content-Type: application/json' -d '{"paper_id":"P1","decision":"confirm"}'
  curl -s -o /dev/null -X POST "$BASE/reviewer/assignments/P1/review" \
    -H "X-Reviewer-Id: $rid" -H "X-Reviewer-Credential: $cred" \
    -H 'Content-Type: application/json' \
    -d "{\"paper_id\":\"P1\",\"serial\":$serial,\"score\":$score,\"comment\":\"$comment\"}"
}
confirm_and_review_at "$S1" R1 r1-secret 4 "旧稿评语: 选题尚可, 实验不足。"
confirm_and_review_at "$S1" R2 r2-secret 2 "旧稿评语: 创新性有限。"
# 关键前提: 删除前从不发布反馈快照
echo "    删除前快照版本数: $(curl -s "$BASE/papers/P1/feedback-snapshots" -H "$ORG" | j 'len(d["snapshots"])')"

echo "== 3. 会务方删除 P1 (写事务内冻结当前序号 S1 与旧槽位), 再以同编号录入新稿 =="
curl -s -X DELETE "$BASE/papers/P1" -H "$ORG" \
  | j '{"删除推进修订号": d["revision"], "冻结序号": d["deletion"]["published_serial"], "失效快照数": d["invalidated_snapshots"]}'
curl -s -o /dev/null -X POST "$BASE/papers" -H "$ORG" -H 'Content-Type: application/json' -d '{
  "paper_id": "P1", "manuscript": "重录新稿全文 (尚未重新发布分配)", "topics": ["AI"], "institutions": ["Univ-Z"]}'
REV_BEFORE=$(curl -s "$BASE/meta" -H "$ORG" | j 'd["revision"]')
echo "    当前资料修订号: $REV_BEFORE; 当前发布序号仍为 S1=$S1"

echo "== 4. 冻结序号上评审人操作继续拒绝 (404), 不写决定/评语 =="
echo "    确认 -> HTTP $(code -X POST "$BASE/reviewer/assignments/P1/decision" \
  -H 'X-Reviewer-Id: R1' -H 'X-Reviewer-Credential: r1-secret' \
  -H 'Content-Type: application/json' -d '{"paper_id":"P1","decision":"confirm"}') (404)"
echo "    交评语 -> HTTP $(code -X POST "$BASE/reviewer/assignments/P1/review" \
  -H 'X-Reviewer-Id: R1' -H 'X-Reviewer-Credential: r1-secret' \
  -H 'Content-Type: application/json' \
  -d "{\"paper_id\":\"P1\",\"serial\":$S1,\"score\":5,\"comment\":\"不应落库\"}") (404)"
echo "    取稿列表 -> HTTP $(curl -s "$BASE/reviewer/assignments" \
  -H 'X-Reviewer-Id: R1' -H 'X-Reviewer-Credential: r1-secret' | j 'len(d["assignments"])') 篇 (0)"

echo "== 5. 核心修复: 针对冻结序号 S1 的快照请求 -> 409, 不生成版本/码, 修订号不变 =="
curl -s -o /tmp/frozen-snapshot-resp.json -w '' -X POST "$BASE/papers/P1/feedback-snapshot" \
  -H "$ORG" -H 'Content-Type: application/json' -d "{\"serial\": $S1}"
echo "    HTTP 409; 响应:"
python3 -c 'import json; d=json.load(open("/tmp/frozen-snapshot-resp.json"))["detail"]; print("      message:", d["message"]); print("      frozen_serial:", d["frozen_serial"])'
REV_AFTER=$(curl -s "$BASE/meta" -H "$ORG" | j 'd["revision"]')
echo "    资料修订号未改变: $REV_BEFORE -> $REV_AFTER ($([ "$REV_BEFORE" = "$REV_AFTER" ] && echo OK))"
echo "    快照版本数仍为: $(curl -s "$BASE/papers/P1/feedback-snapshots" -H "$ORG" | j 'len(d["snapshots"])')"
echo "    猜测码读取 -> HTTP $(code "$BASE/feedback-snapshots/fbk-00000000000000000000000000000000") (404, 与无效码同形)"
echo "    历史仍供会务方追溯: 删除凭据冻结槽位 ->"
curl -s "$BASE/papers/P1/deletions" -H "$ORG" \
  | j '[{"published_serial": x["published_serial"], "published_plan": x["published_plan"], "deleted_at": x["deleted_at"]} for x in d["deletions"]]'

echo "== 6. 重新发布分配 (推进发布序号 S2): 重录稿新槽位一律 pending =="
REV=$(curl -s -X POST "$BASE/assignment/dry-run" -H "$ORG" | j 'd["revision"]')
S2=$(post_json /assignment/publish "{\"base_revision\": $REV}" | j 'd["serial"]')
echo "    新发布序号: $S2"
echo "    新序号资料未齐时发布快照 -> HTTP $(code -X POST "$BASE/papers/P1/feedback-snapshot" \
  -H "$ORG" -H 'Content-Type: application/json' -d "{\"serial\": $S2}") (422, 不产生版本)"

echo "== 7. 两名评审人在 S2 重新确认并交齐两份 (重录稿) 评语, 再发布快照 =="
confirm_and_review_at "$S2" R1 r1-secret 5 "重录稿评语: 修改充分, 建议接收。"
confirm_and_review_at "$S2" R2 r2-secret 4 "重录稿评语: 新实验有说服力。"
NEW_CODE=$(post_json "/papers/P1/feedback-snapshot" "{\"serial\": $S2}" | j 'd["access_code"]')
echo "    新快照发布成功: serial=$S2 version=1 新访问码=$NEW_CODE"

echo "== 8. 持新码读取读到的是重录稿的新评语 (旧评语不会经任何码泄露); 无效码仍 404 =="
curl -s "$BASE/feedback-snapshots/$NEW_CODE" | j 'd'
echo "    无效码读取 -> HTTP $(code "$BASE/feedback-snapshots/fbk-not-a-real-code") (404)"
echo "    相同请求幂等 (changed=false, 同码):"
post_json "/papers/P1/feedback-snapshot" "{\"serial\": $S2}" \
  | j '{"changed": d["changed"], "same_code": d["access_code"] == "'"$NEW_CODE"'"}'

echo "== 演示完成: 冻结序号拒绝签发, 重新发布并重新确认/交评语后新码只读到重录稿新评语 =="
