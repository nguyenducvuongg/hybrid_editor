# Hướng dẫn Thiết lập Global 4 Công cụ & Quy trình Spec Kit + Graphify

Tài liệu này hướng dẫn **Antigravity 2.0** tự động kiểm tra, cài đặt **4 repo ở phạm vi Global** (dùng chung cho `hybrid_edit_vid` và mọi dự án sau này) sao cho **không xung đột**, sau đó khởi tạo đúng thứ tự vào repo `hybrid_edit_vid`.

> **Nguyên tắc an toàn:** Luôn chạy phần Kiểm tra (chỉ đọc) trước và **chờ Product Owner phê duyệt** rồi mới thực thi các lệnh cài đặt Global hoặc khởi tạo repo.

---

## 1. Kiểm tra hiện trạng máy & 4 công cụ Global (Chỉ đọc — Bước 2 của Phase 0)

```bash
# 1. Phần cứng & Hệ điều hành (MacBook Pro M4 Pro)
uname -m && sw_vers && sysctl -n machdep.cpu.brand_string && sysctl -n hw.memsize && df -h /

# 2. Công cụ biên dịch & media lõi
git --version
rustc --version && cargo --version
cmake --version
ffmpeg -version | head -n 5
ffmpeg -encoders 2>/dev/null | grep videotoolbox

# 3. Runtime cho Toolchain & AI cục bộ
python3 --version
uv --version 2>/dev/null || echo "uv: missing"
node --version 2>/dev/null || echo "node: missing"
npx --version 2>/dev/null || echo "npx: missing"
ollama --version 2>/dev/null || echo "ollama: not installed"

# 4. Trạng thái hiện tại của Antigravity & 4 công cụ Global
agy --version 2>/dev/null || echo "agy CLI: not in PATH"
specify version 2>/dev/null || echo "specify-cli: missing"
which graphify && graphify --help | head -n 5 || echo "graphify: missing"
ls -la ~/.gemini/config/plugins/ 2>/dev/null || echo "no global plugins dir"
ls -la ~/.gemini/config/skills/ 2>/dev/null || echo "no global skills dir"
ls -la ~/.agents/skills/ 2>/dev/null || echo "no ~/.agents/skills dir"
```

---

## 2. Kịch bản Tự động Cài đặt 4 Repo ở Global (Chạy sau khi Owner duyệt)

Mục tiêu: Cài 1 lần dùng cho **mọi dự án về sau** trên Antigravity 2.0, tuyệt đối tránh cài tràn lan gây xung đột.

### A. Cài CLI của `github/spec-kit` và `Graphify-Labs/graphify` qua `uv`
```bash
uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
uv tool install graphifyy
uv tool update-shell
```
*Xác minh:* `specify version` và `graphify --help` đều chạy bình thường.

### B. Cài `DietrichGebert/ponytail` làm Global Plugin của Antigravity
```bash
agy plugin install https://github.com/DietrichGebert/ponytail
```
*Lưu ý:* Plugin được cài vào `~/.gemini/config/plugins/`. Sau khi cài, mọi dự án đều gọi được `/ponytail-review`, `/ponytail-audit`, `/ponytail-debt`.

### C. Cài CHỌN LỌC đúng 4 skill chiến thuật từ `addyosmani/agent-skills` (Chống xung đột Spec Kit)
**KHÔNG** cài toàn bộ 26 skill (`agy plugin install addyosmani/agent-skills`) để tránh xung đột với quy trình `/speckit-*` và tránh ngốn token khởi đầu phiên chat.

Chỉ cài đúng 4 skill không chồng chéo:
1. `test-driven-development`
2. `code-review-and-quality`
3. `interview-me`
4. `context-engineering`

**Cách cài đặt và đồng bộ chuẩn vào `~/.gemini/config/skills/` (Antigravity chỉ quét sâu 1 cấp thư mục):**
```bash
# Cách 1: Cài bằng npx skills ở chế độ global (kiểm tra vị trí đích thực tế sau khi chạy)
npx skills add addyosmani/agent-skills -g --skill test-driven-development
npx skills add addyosmani/agent-skills -g --skill code-review-and-quality
npx skills add addyosmani/agent-skills -g --skill interview-me
npx skills add addyosmani/agent-skills -g --skill context-engineering

# Xác minh và đảm bảo 4 thư mục skill hiện diện đúng 1 cấp trong ~/.gemini/config/skills/
mkdir -p ~/.gemini/config/skills
for s in test-driven-development code-review-and-quality interview-me context-engineering; do
  if [ -d "$HOME/.agents/skills/$s" ] && [ ! -e "$HOME/.gemini/config/skills/$s" ]; then
    ln -s "$HOME/.agents/skills/$s" "$HOME/.gemini/config/skills/$s"
  fi
done
ls -la ~/.gemini/config/skills/
```
*(Nếu `npx skills` không hoạt động hoặc yêu cầu tương tác, Antigravity có thể clone tạm `https://github.com/addyosmani/agent-skills.git` vào `/tmp/addy-skills-tmp`, chỉ copy đúng 4 thư mục skill trên vào `~/.gemini/config/skills/`, rồi xóa thư mục tạm — luôn xác nhận lại không có skill `spec*` hay `plan*` nào của Addy nằm trong `~/.gemini/config/skills/`.)*

### D. Kiểm tra xung đột & Điểm dừng nạp lại Antigravity 2.0
1. Xác minh lại danh sách trong `~/.gemini/config/plugins/` và `~/.gemini/config/skills/` chỉ chứa:
   - Plugin: `ponytail` (không có full `addyosmani/agent-skills`).
   - Global Skills: đúng 4 skill chiến thuật của Addy Osmani.
2. **Thông báo Product Owner thoát hẳn app Antigravity 2.0 (`Cmd+Q`) và mở lại** nếu vừa cài mới plugin/skill Global hoặc vừa cập nhật `$PATH`, để GUI nạp đầy đủ 4 công cụ trước khi bước sang Bước 3.

---

## 3. Khởi tạo Tầng Dự án `hybrid_edit_vid` (BẮT BUỘC làm ĐÚNG THỨ TỰ)

> **Cảnh báo chống xung đột Git:** KHÔNG chạy `specify init` hay `graphify antigravity install` trước khi clone `jub0t/Concat`.

### Bước 1: Clone `jub0t/Concat` sạch sẽ (giữ nguyên `./kit/`)
Vì thư mục dự án hiện đã có `./kit/`, `README.md`, `ANTIGRAVITY_BOOTSTRAP_PROMPT.md`, clone Concat vào thư mục tạm rồi chuyển cấu trúc `.git` + mã nguồn vào workspace (hoặc theo cấu trúc đã chốt với Owner ở Clarification Gate), đổi remote gốc thành `upstream`, và tạo nhánh nền:
```bash
# Minh họa sau khi mã nguồn Concat đã nằm tại gốc repo cùng ./kit/
git remote rename origin upstream
git checkout -b chore/bootstrap-hybrid-edit-vid
```

### Bước 2: Khởi tạo Spec Kit & Graphify trong repo `hybrid_edit_vid`
```bash
# 1. Khởi tạo Spec Kit tích hợp gốc cho Antigravity
specify init --here --force --integration agy --script sh

# 2. Gắn cấu hình Graphify cho Antigravity trong repo
graphify antigravity install

# 3. Thêm graphify-out/ vào .gitignore để không commit cache đồ thị lên Git
grep -qxF 'graphify-out/' .gitignore || echo 'graphify-out/' >> .gitignore

# 4. Tạo thư mục tách biệt cho Runtime Video-Editing Skills (không đụng .agents/skills/)
mkdir -p assets/editor-skills

# 5. (Tùy chọn) Cài git hook tự cập nhật AST graph sau mỗi commit (0 token LLM)
graphify hook install
```

---

## 4. Phase 0: Giải phẫu Mã nguồn `Concat` bằng Graphify trước khi lập kế hoạch M1

Ngay sau khi hoàn tất Bước 2 ở trên:
1. Chạy `/graphify .` để Graphify dựng Knowledge Graph toàn bộ các crate Rust và file giao diện Slint của Concat vào `graphify-out/`.
2. Đọc `graphify-out/GRAPH_REPORT.md` và dùng `graphify query` / `graphify path` để trả lời chính xác **4 câu hỏi giải phẫu kiến trúc gốc** kèm **tên tệp + tên hàm/struct thực tế**, ghi kết quả vào `PROJECT.md`:
   - **Q1 (Command Flow):** Một thao tác chỉnh sửa timeline đi từ sự kiện UI Slint qua các struct/hàm nào tới khi ghi xuống đĩa?
   - **Q2 (Undo/Redo):** Lõi Command của Concat quản lý ngăn xếp Undo/Redo bằng cấu trúc dữ liệu nào? Cần mở rộng gì để hỗ trợ `AgentTurn` (Batch Undo)?
   - **Q3 (Lock & Automation):** Cơ chế `concat.lock` và `concat --mcp` / `editor-api` hiện nằm ở những crate/file nào, và điểm chặn cụ thể nào đang ngăn Live Mode?
   - **Q4 (Renderer Parity):** Đường Preview trên Slint và đường Export FFmpeg chia sẻ chung những module nào, khác nhau ở điểm nào (kiểm tra rủi ro P2 & bất biến I3)?
3. Chạy `/speckit-constitution` nạp toàn bộ `kit/CONSTITUTION_SEED.md` vào `.specify/memory/constitution.md`.
4. Build thử Concat trên MacBook Pro M4 Pro, xác nhận export 5 giây MP4 qua VideoToolbox bằng `ffprobe` để đóng **Milestone 0**.

---

## 5. Vòng đời phát triển chuẩn cho từng Milestone lớn (M1 -> M4)

1. `/speckit-specify` — Viết `spec.md` định rõ hành vi, kịch bản biên và Exit Test định lượng.
2. `/speckit-clarify` (kết hợp `interview-me` nếu cần) — Chốt mọi điểm mơ hồ với Product Owner.
3. `/speckit-plan` (tham chiếu đồ thị `graphify` trước khi thiết kế) — Sinh `plan.md`, `data-model.md`, `research.md` và khóa cứng **`contracts/`**.
4. `/speckit-tasks` — Chia task theo thứ tự phụ thuộc (luôn đặt task viết Regression Test trước task implement cho các Pitfalls).
5. `/speckit-implement` (tuân thủ `test-driven-development`: Red -> Green -> Refactor) — Code và chạy test định lượng trên M4 Pro.
6. `/ponytail-review` — Rà soát dọn code thừa/over-engineering (không xâm phạm I1–I6, `contracts/` và tests).
7. `code-review-and-quality` + `/speckit-analyze` + cập nhật `PROJECT.md` — Nghiệm thu toàn bộ Milestone trước khi sang bước tiếp theo.
