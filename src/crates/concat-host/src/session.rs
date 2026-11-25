// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jareer Abdullah

//! The engine-owned editing session.
//!
//! Open a project folder and the engine holds the edit: every mutation is a
//! `concat_project` [`Command`], applied with undo recorded, and the new
//! state is what the window draws. The window never keeps a model of its
//! own; it renders the [`Project`] this session hands back.
//!
//! Saving reuses `projects::save`'s temp-file-and-rename, so the document on
//! disk is written by exactly one code path.

use concat_project::model::VideoSettings;
use concat_project::{
    Command, DocumentSettings, Editor, Project, TurnCommit, TurnMeta, UnreadSummary,
    touched_clip_ids,
};
use serde::Serialize;

use crate::lease::{LeaseError, LeaseManager, LeaseRole, RecoveredLease, SessionLease, now_unix_ms};
use crate::projects;

/// Origin of a committed document mutation (`StateDiffEvent`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum MutationSource {
    /// Manual user edit from UI or direct API command.
    Manual,
    /// Committed transactional `AgentTurn`.
    AgentTurn {
        /// Turn identifier.
        turn_id: String,
        /// Turn summary.
        summary: String,
    },
    /// Undo step.
    Undo,
    /// Redo step.
    Redo,
    /// Automatic rollback of an uncommitted turn after client crash/lease expiry (`P8`).
    LeaseRollback {
        /// Rolled-back turn identifier.
        turn_id: String,
    },
}

/// Revision-stamped diff notification emitted after document mutations (`I1`, `I2`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StateDiffEvent {
    /// Monotonic document revision after the mutation.
    pub revision: u64,
    /// What triggered the state change.
    pub source: MutationSource,
    /// Clip IDs added or modified relative to the prior state.
    pub affected_clip_ids: Vec<String>,
    /// Whether undo is currently available.
    pub can_undo: bool,
    /// Whether redo is currently available.
    pub can_redo: bool,
}

/// One open project: its folder, its settings and its undo history.
pub struct Session {
    /// The project folder, for saving.
    path: String,
    settings: DocumentSettings,
    editor: Editor,
    /// The links to retired effects the open rewrote, old id and new, each
    /// pair once: what the window names as the project opens.
    upgraded: Vec<(String, String)>,
    /// The clips whose retired fields the open took off.
    retired: concat_project::RetiredFields,
    /// How much of the document this build could not read, held unchanged
    /// for every save to write back: what the window tells the person.
    unread: UnreadSummary,
}

/// What every mutating call returns: the authoritative state plus history
/// availability, so undo/redo affordances are never guessing.
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct EditorView {
    /// The whole project, as the engine holds it.
    pub project: Project,
    /// Whether there is something to undo.
    pub can_undo: bool,
    /// Whether there is something to redo.
    pub can_redo: bool,
    /// The settings as the session holds them - the document's own output
    /// size wins over the manifest's on open.
    pub settings: SettingsView,
    /// The id a creating command minted, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_id: Option<String>,
}

/// The session's settings, as the window shows them.
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct SettingsView {
    /// Project name.
    pub name: String,
    /// Output width in pixels.
    pub width: u32,
    /// Output height in pixels.
    pub height: u32,
    /// Frame rate numerator.
    pub rate_num: i64,
    /// Frame rate denominator.
    pub rate_den: i64,
}

impl Session {
    /// Opens a project folder as the editing session.
    ///
    /// A folder with no document yet opens as an empty project rather than
    /// failing, but a document that is there and cannot be read or parsed
    /// is an error, because silently replacing an edit with emptiness is
    /// how projects get lost. `settings` come from the manifest and seed the first timeline
    /// of a project that has no document yet; a document that loads brings
    /// every timeline's own frame with it, and those win, because that is
    /// where an edited frame was saved.
    pub fn open(path: &str, settings: DocumentSettings) -> Result<Session, String> {
        // The document's bytes, as read, for the copy kept once it opens.
        let mut stored: Option<Vec<u8>> = None;
        let editor = match projects::read_document_as_stored(path) {
            Ok(Some((document, bytes))) => match Editor::from_document(&document) {
                Some(editor) => {
                    stored = Some(bytes);
                    editor
                }
                // The settings-only manifest `create` writes: a project
                // closed before its first edit reopens empty, it is not
                // corrupt.
                None if projects::is_settings_only(&document) => {
                    stored = Some(bytes);
                    Editor::with_video(settings.video())
                }
                None if concat_project::document_version(&document)
                    > concat_project::DOCUMENT_VERSION =>
                {
                    return Err(format!(
                        "{path} was saved by a newer Concat than this one: update to open it"
                    ));
                }
                None => {
                    return Err(format!("{path} holds a document this build cannot read"));
                }
            },
            // No document yet - a project created moments ago.
            Ok(None) => Editor::with_video(settings.video()),
            // Unreadable or not JSON: a save cut short, a disk in trouble.
            // The one thing open must not do is answer with an empty
            // project, since the next save would replace what was edited.
            Err(error) => return Err(error),
        };
        // A link to a retired effect opens as a link to the one that stands
        // in for it, its knobs carried over (`[[replaces]]`).
        let mut editor = editor;
        let catalogue = concat_effects::Catalogue::builtin();
        let mut upgraded: Vec<(String, String)> = Vec::new();
        editor.upgrade_links(|link| {
            let old = link.id.clone();
            let changed = catalogue.upgrade(link);
            let pair = (old, link.id.clone());
            // A link carried over to its own package's newer version opens
            // as it looked, near enough, and says nothing.
            if changed && pair.0 != pair.1 && !upgraded.contains(&pair) {
                upgraded.push(pair);
            }
            changed
        });
        // Fields an earlier version wrote and this one does not read, off
        // the clips, with the clips named for the window to say so.
        let retired = editor.drop_retired_fields();
        // What this build cannot read stays in the document, unchanged, and
        // every save writes it back; the person is told by the window.
        let unread = editor.project().unread_summary();
        if !unread.is_empty() {
            log::warn!(
                "project: opened with parts this build cannot read, kept unchanged in the file and not shown · {} clips, {} media, {} timelines, {} other parts",
                unread.clips,
                unread.media,
                unread.timelines,
                unread.parts
            );
        }
        // The file as this open found it, kept before any save of this run
        // can replace it.
        if let Some(bytes) = stored
            && let Err(error) = projects::keep_opened_copy(path, &bytes)
        {
            log::warn!(
                "project: keeping a copy of the document as opened failed: {error}; it opens all the same"
            );
        }
        Ok(Session {
            path: path.to_owned(),
            settings,
            editor,
            upgraded,
            retired,
            unread,
        })
    }

    /// Opens the project a [`projects::ProjectInfo`] describes.
    pub fn open_info(info: &projects::ProjectInfo) -> Result<Session, String> {
        Session::open(
            &info.path,
            DocumentSettings {
                name: info.name.clone(),
                width: info.width,
                height: info.height,
                rate_num: info.rate_num,
                rate_den: info.rate_den,
                canvas: info.canvas,
            },
        )
    }

    /// The links to retired effects this open read as links to the
    /// effects that stand in for them, old id and new. Empty when the
    /// document named none; the change is the document's once it is saved.
    pub fn upgraded(&self) -> &[(String, String)] {
        &self.upgraded
    }

    /// The clips this open found with fields an earlier version wrote and
    /// this one no longer reads, now taken off: reversed ones that play
    /// forwards, animated ones that hold still. Empty for most documents.
    pub fn retired(&self) -> &concat_project::RetiredFields {
        &self.retired
    }

    /// How much of the document this open could not read: clips, media,
    /// timelines and parts of clips this build cannot show, held unchanged
    /// and written back by every save. Empty for most documents.
    pub fn unread(&self) -> UnreadSummary {
        self.unread
    }

    /// The project folder.
    pub fn path(&self) -> &str {
        &self.path
    }

    /// The session's settings: the project's name, and the frame and rate of
    /// the timeline being edited.
    ///
    /// Built rather than stored, because the frame is the active timeline's
    /// and the active timeline changes under a tab click. Everything that
    /// renders - the monitor, the export - asks here and gets the frame of
    /// whatever it is about to draw.
    pub fn settings(&self) -> DocumentSettings {
        let video = self.editor.project().active().video;
        DocumentSettings {
            name: self.settings.name.clone(),
            width: video.width,
            height: video.height,
            rate_num: video.rate_num,
            rate_den: video.rate_den,
            canvas: video.canvas,
        }
    }

    /// The active timeline's frame and rate.
    pub fn video(&self) -> VideoSettings {
        self.editor.project().active().video
    }

    /// Sets the active timeline's frame and rate, as an edit - undoable,
    /// and this timeline's alone. Anything a frame could not be is ignored
    /// by the command, for the reason a zero dimension is in
    /// [`Session::prepare_save`].
    pub fn set_video(&mut self, video: VideoSettings) -> Result<EditorView, String> {
        let timeline_id = self.editor.project().active_timeline_id.clone();
        self.apply(Command::SetTimelineVideo { timeline_id, video })
    }

    /// The edit as it stands.
    pub fn project(&self) -> &Project {
        self.editor.project()
    }

    /// Whether there is something to undo.
    pub fn can_undo(&self) -> bool {
        self.editor.can_undo()
    }

    /// Whether there is something to redo.
    pub fn can_redo(&self) -> bool {
        self.editor.can_redo()
    }

    /// The current state without changing anything.
    pub fn view(&self) -> EditorView {
        self.view_with(None)
    }

    fn view_with(&self, created_id: Option<String>) -> EditorView {
        let settings = self.settings();
        EditorView {
            project: self.editor.project().clone(),
            can_undo: self.editor.can_undo(),
            can_redo: self.editor.can_redo(),
            settings: SettingsView {
                name: settings.name,
                width: settings.width,
                height: settings.height,
                rate_num: settings.rate_num,
                rate_den: settings.rate_den,
            },
            created_id,
        }
    }

    /// Applies one edit command and returns the new state.
    pub fn apply(&mut self, command: Command) -> Result<EditorView, String> {
        self.apply_within(None, command)
    }

    /// Applies one edit command and returns both the updated `EditorView` and a `StateDiffEvent`.
    pub fn apply_tracked(&mut self, command: Command) -> Result<(EditorView, StateDiffEvent), String> {
        let is_view = command.is_view_state();
        let before = self.editor.project().clone();
        let view = self.apply_within(None, command)?;
        let affected = if is_view {
            Vec::new()
        } else {
            touched_clip_ids(&before, self.editor.project())
        };
        let event = StateDiffEvent {
            revision: self.editor.revision(),
            source: MutationSource::Manual,
            affected_clip_ids: affected,
            can_undo: view.can_undo,
            can_redo: view.can_redo,
        };
        Ok((view, event))
    }

    /// Current monotonic document revision.
    pub fn revision(&self) -> u64 {
        self.editor.revision()
    }

    /// Active uncommitted turn ID, if any.
    pub fn active_turn_id(&self) -> Option<&str> {
        self.editor.active_turn_id()
    }

    /// Metadata of the latest undoable `AgentTurn`, if at top of Undo stack.
    pub fn top_undo_turn(&self) -> Option<&TurnMeta> {
        self.editor.top_undo_turn()
    }

    /// Opens a transactional `AgentTurn` on the underlying `Editor`.
    pub fn begin_agent_turn(&mut self, turn_id: &str, summary: &str) -> Result<(), String> {
        self.editor
            .begin_agent_turn(turn_id, summary)
            .map_err(|e| e.to_string())
    }

    /// Executes one command inside an open `AgentTurn`.
    pub fn apply_in_turn(&mut self, turn_id: &str, command: Command) -> Result<EditorView, String> {
        let outcome = self
            .editor
            .apply_in_turn(turn_id, command)
            .map_err(|e| e.to_string())?;
        Ok(self.view_with(outcome.created_id))
    }

    /// Commits an active `AgentTurn` as 1 unified Undo/Redo entry and emits `StateDiffEvent`.
    pub fn commit_agent_turn(
        &mut self,
        turn_id: &str,
    ) -> Result<(EditorView, TurnCommit, StateDiffEvent), String> {
        let commit = self
            .editor
            .commit_agent_turn(turn_id)
            .map_err(|e| e.to_string())?;
        let view = self.view();
        let event = StateDiffEvent {
            revision: commit.revision,
            source: MutationSource::AgentTurn {
                turn_id: commit.turn_id.clone(),
                summary: commit.summary.clone(),
            },
            affected_clip_ids: commit.affected_clip_ids.clone(),
            can_undo: view.can_undo,
            can_redo: view.can_redo,
        };
        Ok((view, commit, event))
    }

    /// Rolls back an active uncommitted `AgentTurn` cleanly.
    pub fn rollback_agent_turn(&mut self, turn_id: &str) -> Result<(EditorView, StateDiffEvent), String> {
        let rev = self
            .editor
            .rollback_agent_turn(turn_id)
            .map_err(|e| e.to_string())?;
        let view = self.view();
        let event = StateDiffEvent {
            revision: rev,
            source: MutationSource::LeaseRollback {
                turn_id: turn_id.to_owned(),
            },
            affected_clip_ids: Vec::new(),
            can_undo: view.can_undo,
            can_redo: view.can_redo,
        };
        Ok((view, event))
    }

    /// Undoes one step and emits a `StateDiffEvent`.
    pub fn undo_tracked(&mut self) -> (EditorView, Option<StateDiffEvent>) {
        if !self.can_undo() {
            return (self.view(), None);
        }
        let before = self.editor.project().clone();
        let view = self.undo();
        let affected = touched_clip_ids(&before, &view.project);
        let event = StateDiffEvent {
            revision: self.editor.revision(),
            source: MutationSource::Undo,
            affected_clip_ids: affected,
            can_undo: view.can_undo,
            can_redo: view.can_redo,
        };
        (view, Some(event))
    }

    /// Redoes one step and emits a `StateDiffEvent`.
    pub fn redo_tracked(&mut self) -> (EditorView, Option<StateDiffEvent>) {
        if !self.can_redo() {
            return (self.view(), None);
        }
        let before = self.editor.project().clone();
        let view = self.redo();
        let affected = touched_clip_ids(&before, &view.project);
        let event = StateDiffEvent {
            revision: self.editor.revision(),
            source: MutationSource::Redo,
            affected_clip_ids: affected,
            can_undo: view.can_undo,
            can_redo: view.can_redo,
        };
        (view, Some(event))
    }

    /// Applies one edit command as a move of `gesture`, so that a knob
    /// dragged through many values is one undo step; see
    /// `concat_project::Editor::apply_within`. `None` is a step of its own.
    pub fn apply_within(
        &mut self,
        gesture: Option<&str>,
        command: Command,
    ) -> Result<EditorView, String> {
        let outcome = self
            .editor
            .apply_within(gesture, command)
            .map_err(|error| error.to_string())?;
        Ok(self.view_with(outcome.created_id))
    }

    /// Ends the gesture in progress: the next command naming it starts a
    /// new undo step.
    pub fn end_gesture(&mut self) {
        self.editor.end_gesture();
    }

    /// Steps the history back one edit.
    pub fn undo(&mut self) -> EditorView {
        self.editor.undo();
        self.view()
    }

    /// Steps the history forward one edit.
    pub fn redo(&mut self) -> EditorView {
        self.editor.redo();
        self.view()
    }

    /// Takes a new name, if there is one, and hands back what a save must
    /// write: the folder and the document. The frame is not a parameter any
    /// more - it is the active timeline's, set through [`Session::set_video`]
    /// as an edit. The disk write is the caller's, so it can happen off the
    /// thread that owns the session; [`Session::save`] does both.
    pub fn prepare_save(&mut self, name: Option<&str>) -> (String, serde_json::Value) {
        if let Some(name) = name {
            let trimmed = name.trim();
            if !trimmed.is_empty() {
                self.settings.name = trimmed.to_owned();
            }
        }
        (self.path.clone(), self.editor.to_document(&self.settings))
    }

    /// Writes the session's document to its project folder.
    pub fn save(&mut self, name: Option<&str>) -> Result<(), String> {
        let (path, document) = self.prepare_save(name);
        projects::save(&path, &document)
    }

    /// The document as it would be saved.
    pub fn document(&self) -> serde_json::Value {
        self.editor.to_document(&self.settings)
    }

    /// The active timeline flattened for rendering. This is what export and
    /// preview consume: the engine flattens its own session, so the pixels
    /// rendered are the model's, never a copy of it.
    pub fn flattened_clips(&self) -> Vec<concat_export::ExportClip> {
        concat_export::flatten::flatten_timeline_in(
            self.editor.project(),
            None,
            Some(std::path::Path::new(&self.path)),
        )
    }
}

/// Callback receiving `StateDiffEvent` notifications from a `LiveSession`.
pub type DiffSubscriber = std::sync::Arc<dyn Fn(&StateDiffEvent) + Send + Sync>;

/// Single-writer coordinated session combining `Session` + `LeaseManager` (`I1`, `I2`, `P8`).
pub struct LiveSession {
    session: Session,
    leases: LeaseManager,
    subscribers: Vec<DiffSubscriber>,
}

impl LiveSession {
    /// Wraps an open `Session` with recoverable lease tracking under `lease_dir`.
    pub fn new(session: Session, lease_dir: std::path::PathBuf, grace: std::time::Duration) -> Self {
        let project_key = session.path().to_owned();
        Self {
            session,
            leases: LeaseManager::new(lease_dir, &project_key, grace),
            subscribers: Vec::new(),
        }
    }

    /// Subscribes a live listener (e.g. Slint UI bridge) for `StateDiffEvent` updates.
    pub fn subscribe(&mut self, sub: DiffSubscriber) {
        self.subscribers.push(sub);
    }

    /// Returns a read-only view of the underlying `Session`.
    pub fn session(&self) -> &Session {
        &self.session
    }

    /// Acquires the write lease, rolling back any uncommitted turn from a crashed/expired holder.
    pub fn acquire_lease(
        &mut self,
        session_id: &str,
        client_pid: u32,
        role: LeaseRole,
        now_ms: u64,
    ) -> Result<(SessionLease, Option<RecoveredLease>), LeaseError> {
        let (lease, recovered) = self.leases.acquire(session_id, client_pid, role, now_ms)?;
        self.rollback_recovered(&recovered);
        Ok((lease, recovered))
    }

    /// Renews heartbeat for `session_id`.
    pub fn heartbeat(
        &mut self,
        session_id: &str,
        client_pid: u32,
        now_ms: u64,
    ) -> Result<SessionLease, LeaseError> {
        self.leases.heartbeat(session_id, client_pid, now_ms)
    }

    /// Releases the held lease for `session_id`, rolling back any uncommitted turn first.
    pub fn release_lease(&mut self, session_id: &str) -> Result<(), LeaseError> {
        if let Some(tid) = self
            .leases
            .current()
            .filter(|l| l.session_id == session_id)
            .and_then(|l| l.active_turn_id.clone())
            && self.session.active_turn_id() == Some(tid.as_str())
            && let Ok((_, ev)) = self.session.rollback_agent_turn(&tid)
        {
            self.emit(&ev);
        }
        self.leases.release(session_id)
    }

    /// Reclaims an expired/dead lease and rolls back any uncommitted turn (`P8`).
    pub fn reclaim_expired(&mut self, now_ms: u64) -> Option<RecoveredLease> {
        let rec = self.leases.reclaim_if_expired(now_ms);
        self.rollback_recovered(&rec);
        rec
    }

    /// Executes a standalone command under `caller_session_id` authorization.
    pub fn apply_for(
        &mut self,
        caller_session_id: Option<&str>,
        command: Command,
    ) -> Result<(EditorView, StateDiffEvent), String> {
        self.authorize_write(caller_session_id)?;
        let (view, ev) = self.session.apply_tracked(command)?;
        self.emit(&ev);
        Ok((view, ev))
    }

    /// Opens an `AgentTurn` under `caller_session_id` authorization.
    pub fn begin_agent_turn_for(
        &mut self,
        caller_session_id: &str,
        turn_id: &str,
        summary: &str,
    ) -> Result<(), String> {
        let now = now_unix_ms();
        self.authorize_write(Some(caller_session_id))?;
        self.session.begin_agent_turn(turn_id, summary)?;
        if let Err(err) = self
            .leases
            .set_active_turn(caller_session_id, Some(turn_id.to_owned()), now)
        {
            let _ = self.session.rollback_agent_turn(turn_id);
            return Err(err.to_string());
        }
        Ok(())
    }

    /// Applies a command inside an active `AgentTurn`.
    pub fn apply_in_turn_for(
        &mut self,
        caller_session_id: &str,
        turn_id: &str,
        command: Command,
    ) -> Result<EditorView, String> {
        self.authorize_write(Some(caller_session_id))?;
        self.session.apply_in_turn(turn_id, command)
    }

    /// Commits an active `AgentTurn` and broadcasts the resulting `StateDiffEvent`.
    pub fn commit_agent_turn_for(
        &mut self,
        caller_session_id: &str,
        turn_id: &str,
    ) -> Result<(EditorView, TurnCommit, StateDiffEvent), String> {
        let now = now_unix_ms();
        self.authorize_write(Some(caller_session_id))?;
        let (view, commit, ev) = self.session.commit_agent_turn(turn_id)?;
        let _ = self.leases.set_active_turn(caller_session_id, None, now);
        self.emit(&ev);
        Ok((view, commit, ev))
    }

    /// Rolls back an active `AgentTurn` and broadcasts the rollback event.
    pub fn rollback_agent_turn_for(
        &mut self,
        caller_session_id: &str,
        turn_id: &str,
    ) -> Result<(EditorView, StateDiffEvent), String> {
        let now = now_unix_ms();
        self.authorize_write(Some(caller_session_id))?;
        let (view, ev) = self.session.rollback_agent_turn(turn_id)?;
        let _ = self.leases.set_active_turn(caller_session_id, None, now);
        self.emit(&ev);
        Ok((view, ev))
    }

    fn authorize_write(&mut self, caller_session_id: Option<&str>) -> Result<(), String> {
        let now = now_unix_ms();
        let rec = self
            .leases
            .check_writer(caller_session_id, now)
            .map_err(|e| e.to_string())?;
        self.rollback_recovered(&rec);
        Ok(())
    }

    fn rollback_recovered(&mut self, rec: &Option<RecoveredLease>) {
        if let Some(rec) = rec
            && let Some(tid) = rec.uncommitted_turn_id.as_deref()
            && self.session.active_turn_id() == Some(tid)
            && let Ok((_, ev)) = self.session.rollback_agent_turn(tid)
        {
            self.emit(&ev);
        }
    }

    fn emit(&self, event: &StateDiffEvent) {
        for sub in &self.subscribers {
            sub(event);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings() -> DocumentSettings {
        DocumentSettings {
            canvas: [0, 0, 0, 255],
            name: "Test".to_owned(),
            width: 1920,
            height: 1080,
            rate_num: 30,
            rate_den: 1,
        }
    }

    #[test]
    fn a_fresh_project_opens_empty_and_round_trips_a_save() {
        let scratch =
            std::env::temp_dir().join(format!("concat-session-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(&scratch).expect("scratch dir");
        let info = projects::create(
            &scratch.to_string_lossy(),
            "Fresh",
            1920,
            1080,
            30,
            1,
            [0, 0, 0, 255],
        )
        .expect("creates");

        let mut session = Session::open_info(&info).expect("opens the settings-only manifest");
        assert!(!session.can_undo());
        assert_eq!(
            (session.settings().width, session.settings().height),
            (1920, 1080),
            "the manifest's frame seeds the first timeline"
        );
        let view = session
            .apply(Command::AddTrack { bottom: false })
            .expect("adds a track");
        assert!(view.can_undo);
        session
            .set_video(VideoSettings {
                canvas: [0, 0, 0, 255],
                width: 1280,
                height: 720,
                rate_num: 25,
                rate_den: 1,
                color_space: Default::default(),
            })
            .expect("sets the frame");
        session.save(Some("Renamed")).expect("saves");

        let reopened = Session::open(&info.path, settings()).expect("reopens");
        assert_eq!(
            reopened.settings().name,
            "Test",
            "the manifest's name is what open gets"
        );
        assert_eq!(
            (reopened.settings().width, reopened.settings().height),
            (1280, 720),
            "the document's frame wins over the manifest's"
        );
        assert_eq!(reopened.settings().rate_num, 25, "and so does its rate");
        assert_eq!(
            reopened.project().active().tracks.len(),
            session.project().active().tracks.len()
        );

        let _ = std::fs::remove_dir_all(&scratch);
    }

    /// A document with parts this build cannot read - a clip of a kind from
    /// a newer build, an effect among readable ones, a media item that does
    /// not parse - opens with the rest, keeps a copy of itself as opened,
    /// and every save writes the parts back as they were.
    #[test]
    fn what_this_build_cannot_read_survives_open_save_and_reopen() {
        use serde_json::json;
        let scratch = tempfile::tempdir().expect("scratch dir");
        let root = scratch.path().join("Newer");
        std::fs::create_dir_all(&root).expect("project folder");
        let newer_clip = json!({ "id": "c2", "trackId": "T1", "kind": "hologram",
                                 "start": 2.0, "duration": 1.0, "beam": "teal" });
        let newer_effect = json!({ "id": "glow", "params": { "amount": "lots" } });
        let newer_media = json!({ "id": "m2", "path": { "cloud": "x" }, "kind": "video" });
        let document = json!({
            "name": "Newer", "version": 2,
            "media": [{ "id": "m1", "path": "/a.mp4", "name": "a.mp4", "kind": "video" },
                      newer_media],
            "timelines": [{
                "id": "TL1", "name": "Timeline 1",
                "tracks": [{ "id": "T1" }],
                "clips": [
                    { "id": "c1", "trackId": "T1", "mediaId": "m1", "kind": "video",
                      "start": 0.0, "duration": 2.0,
                      "videoEffects": [{ "id": "sepia" }, newer_effect] },
                    newer_clip
                ]
            }],
            "activeTimelineId": "TL1"
        });
        let bytes = serde_json::to_vec_pretty(&document).expect("encodes");
        std::fs::write(root.join("concat.json"), &bytes).expect("writes");
        let path = root.to_string_lossy().into_owned();

        let mut session = Session::open(&path, settings()).expect("opens");
        assert_eq!(
            session.unread(),
            UnreadSummary {
                clips: 1,
                media: 1,
                timelines: 0,
                parts: 1,
            }
        );
        assert_eq!(session.project().active().clips.len(), 1);
        // The file as opened, kept beside it before any save.
        assert_eq!(
            std::fs::read(root.join("concat.opened.json")).expect("the copy"),
            bytes
        );

        session
            .apply(Command::AddTrack { bottom: false })
            .expect("edits");
        session.save(None).expect("saves");
        let reopened = Session::open(&path, settings()).expect("reopens");
        assert_eq!(reopened.unread(), session.unread(), "nothing was lost");
        let saved = projects::read_document(&path)
            .expect("reads")
            .expect("a document");
        let clips = saved["timelines"][0]["clips"].as_array().expect("clips");
        assert!(clips.contains(&newer_clip));
        assert_eq!(clips[0]["videoEffects"][1], newer_effect);
        assert!(
            saved["media"]
                .as_array()
                .expect("media")
                .contains(&newer_media)
        );
        // The reopen kept the saved document as its copy, and the copy is
        // never taken for a project's manifest.
        assert_eq!(
            std::fs::read(projects::opened_copy_path(&root)).expect("the copy"),
            std::fs::read(projects::manifest_path(&root)).expect("the manifest")
        );
        assert!(projects::manifest_path(&root).ends_with("concat.json"));
    }

    #[test]
    fn a_corrupt_document_is_refused() {
        let scratch =
            std::env::temp_dir().join(format!("concat-corrupt-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(&scratch).expect("scratch dir");
        std::fs::write(scratch.join("concat.json"), br#"{"timelines": "garbage"}"#)
            .expect("writes");
        assert!(Session::open(&scratch.to_string_lossy(), settings()).is_err());
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[test]
    fn a_truncated_document_is_refused_rather_than_replaced() {
        let scratch =
            std::env::temp_dir().join(format!("concat-truncated-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(&scratch).expect("scratch dir");
        // A save cut short by a power cut or an outside tool: the file is
        // there, and it is not JSON. Opening it as an empty project would
        // let the next save replace whatever was edited.
        std::fs::write(
            scratch.join("concat.json"),
            br#"{"version": 1, "timelines": ["#,
        )
        .expect("writes");
        let opened = Session::open(&scratch.to_string_lossy(), settings());
        assert!(opened.is_err(), "a half document is not an empty project");
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[test]
    fn p4_view_state_does_not_write_or_pollute_undo() {
        let scratch = tempfile::tempdir().expect("scratch");
        let info = projects::create(
            &scratch.path().to_string_lossy(),
            "P4Test",
            1920,
            1080,
            30,
            1,
            [0, 0, 0, 255],
        )
        .expect("create");
        let mut session = Session::open_info(&info).expect("open");
        session.apply(Command::AddTimeline).expect("add second timeline");
        session.save(None).expect("save baseline");
        // Drain undo via reopening cleanly so Undo starts empty.
        let mut session = Session::open_info(&info).expect("reopen clean");
        let timeline_ids: [String; 2] = [
            session.project().timelines[0].id.clone(),
            session.project().timelines[1].id.clone(),
        ];
        let rev0 = session.revision();

        let disk_snapshot = |dir: &str| -> Vec<(String, Vec<u8>)> {
            let mut entries = Vec::new();
            for entry in std::fs::read_dir(dir).expect("read project dir") {
                let path = entry.expect("dir entry").path();
                if path.is_file() {
                    entries.push((
                        path.file_name().unwrap().to_string_lossy().into_owned(),
                        std::fs::read(&path).expect("read file"),
                    ));
                }
            }
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            entries
        };
        let baseline_disk = disk_snapshot(&info.path);

        // 20 view-state timeline switches create 0 undo entries, 0 revision bumps, 0 disk writes.
        for i in 0..20 {
            let (view, diff) = session
                .apply_tracked(Command::SelectTimeline {
                    timeline_id: timeline_ids[i % 2].clone(),
                })
                .expect("select timeline");
            assert!(!view.can_undo);
            assert_eq!(diff.revision, rev0);
            assert!(diff.affected_clip_ids.is_empty());
        }
        assert_eq!(session.revision(), rev0);
        assert!(!session.can_undo());
        assert_eq!(disk_snapshot(&info.path), baseline_disk);

        // 1 document edit creates exactly 1 undo entry and bumps revision once.
        let (view, diff) = session
            .apply_tracked(Command::AddTrack { bottom: false })
            .expect("add track");
        assert!(view.can_undo);
        assert_eq!(diff.revision, rev0 + 1);
        assert_eq!(session.revision(), rev0 + 1);
    }

    #[test]
    fn hybrid_100_ops_interleaved_manual_and_agent_turns() {
        let scratch = tempfile::tempdir().expect("scratch");
        let info = projects::create(
            &scratch.path().to_string_lossy(),
            "Stress100",
            1920,
            1080,
            30,
            1,
            [0, 0, 0, 255],
        )
        .expect("create");
        let mut session = Session::open_info(&info).expect("open");
        for i in 0..25 {
            session
                .apply_tracked(Command::AddTrack { bottom: false })
                .expect("manual add");
            let tid = format!("turn-{i}");
            session.begin_agent_turn(&tid, "Batch").expect("begin");
            session
                .apply_in_turn(
                    &tid,
                    Command::AddTextClip {
                        track_id: None,
                        above: false,
                        start: i as f64,
                        style: None,
                        duration: Some(1.0),
                        offset_y: None,
                    },
                )
                .expect("add text");
            session.commit_agent_turn(&tid).expect("commit");
            let _ = session.undo_tracked();
            let _ = session.redo_tracked();
        }
        assert!(session.revision() >= 50);
    }
}
