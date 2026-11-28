# HybridEditVid Starter Kit v2 (`hybrid_edit_vid`)

Bộ tài liệu khởi tạo **phiên bản v2** dành riêng cho **Antigravity 2.0** trên **macOS Apple Silicon (MacBook Pro M4 Pro)** để:
1. **Tự động thiết lập bộ 4 công cụ AI Coding chuẩn Global (không xung đột)** dùng chung cho dự án này và mọi dự án sau này (`spec-kit`, `graphify`, `ponytail`, và 4 skill chiến thuật chọn lọc của `addyosmani/agent-skills`).
2. **Xây dựng nền tảng dựng phim Hybrid `hybrid_edit_vid`** phát triển từ lõi **Concat (Rust + Slint)** kết hợp tư duy AI-native của **OpenChatCut**.

## Cấu trúc gói tài liệu trong `kit/`

| Tệp | Vai trò |
| :--- | :--- |
| `kit/README.md` | Hướng dẫn sử dụng nhanh và bản đồ tài liệu khởi tạo. |
| `kit/ANTIGRAVITY_BOOTSTRAP_PROMPT.md` | **Prompt tổng v2** để dán làm tin nhắn đầu tiên trong Antigravity 2.0. |
| `kit/PROJECT_BRIEF.md` | Toàn bộ yêu cầu đã chốt: lõi Concat (Rust + Slint), Hybrid Timeline, Antigravity + Ollama/LM Studio, phạm vi v0.1 (A-roll & B-roll) và mở rộng v0.2+. |
| `kit/CONSTITUTION_SEED.md` | Hạt giống cho `/speckit-constitution`: 6 bất biến kiến trúc (I1–I6), **Thứ bậc ưu tiên 4 công cụ** (Hiến pháp > Spec Kit > Graphify > Ponytail/Addy Skills), tối ưu M4 Pro và kỷ luật kiểm thử. |
| `kit/PITFALLS_AND_FIXES.md` | Các lỗi tích hợp thực chiến (P1, P2, P3, P4, P6, P7, P8, P9) kèm bài test hồi quy bắt buộc viết trước khi sửa (TDD). |
| `kit/TOOLCHAIN_AND_SPECKIT_GUIDE.md` | Hướng dẫn Antigravity tự động cài 4 repo ở Global (chống xung đột), tách biệt bước cài Global vs bước Init theo repo, và quy trình dùng `/graphify .` giải phẫu Concat ở Phase 0. |
| `kit/EDITOR_SKILLS_SPEC.md` | Đặc tả hệ thống Video-Editing Skills runtime (`assets/editor-skills/`) và bộ Semantic/Perception MCP Tools. |
