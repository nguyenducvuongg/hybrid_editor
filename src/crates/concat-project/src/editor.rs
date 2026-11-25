// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Jareer Abdullah

//! The editing session: a project, its id mint, and undo.
//!
//! Undo is whole-state snapshots, and they are cheap: the project's
//! timelines and clips sit behind `Arc`, so a snapshot copies pointers and
//! a command copies only the clip it writes to. Impossible to get wrong in
//! the way inverse operations are, and a heavy project's two hundred undos
//! are a few megabytes, not a few hundred.
//!
//! Two refinements on "one snapshot per command":
//!
//! - A **gesture** is one undo step. A knob being dragged commits on every
//!   pause of the pointer; the caller names the gesture, and commits that
//!   name the same gesture as the last recorded step fold into it. See
//!   [`Editor::apply_within`].
//! - **View state is not an edit.** Which timeline tab is showing, and the
//!   order of the tabs, is saved with the document but never recorded in
//!   history: undo steps back through what changed the picture, not
//!   through what the person was looking at.

use crate::model::AppliedFilter;
use std::collections::VecDeque;

use serde_json::Value;

use crate::commands::{Command, CommandError, IdMint, Outcome, apply};
use crate::doc::{DocumentSettings, from_document, to_document};
use crate::model::{Clip, Project};

const UNDO_DEPTH: usize = 200;

/// Metadata describing a committed transactional `AgentTurn` on the Undo stack.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct TurnMeta {
    /// Unique turn identifier.
    pub turn_id: String,
    /// Human-readable turn summary for Hybrid Timeline HUD and Undo display.
    pub summary: String,
    /// Deduplicated clip IDs added or modified by this turn.
    pub affected_clip_ids: Vec<String>,
    /// Document revision after the turn committed.
    pub revision: u64,
}

/// Result returned when an `AgentTurn` commits cleanly.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct TurnCommit {
    /// Committed turn identifier.
    pub turn_id: String,
    /// Turn summary.
    pub summary: String,
    /// Document revision after commit.
    pub revision: u64,
    /// Clip IDs added or modified relative to the pre-turn baseline.
    pub affected_clip_ids: Vec<String>,
    /// True if at least one document change was pushed as 1 Undo step.
    pub pushed_undo_step: bool,
}

/// Errors from transactional `AgentTurn` lifecycle calls.
#[derive(Clone, PartialEq, Debug)]
pub enum TurnError {
    /// Another turn is already open.
    AlreadyActive {
        /// Currently open turn identifier.
        active_turn_id: String,
    },
    /// No turn is currently active.
    NotActive,
    /// Caller supplied a `turn_id` that does not match the active turn.
    TurnMismatch {
        /// Active turn identifier.
        expected: String,
        /// Supplied turn identifier.
        actual: String,
    },
    /// Turn validation failed (e.g. empty turn_id or summary).
    Invalid(String),
    /// An underlying edit command failed inside the turn.
    CommandFailed(CommandError),
}

impl std::fmt::Display for TurnError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TurnError::AlreadyActive { active_turn_id } => {
                write!(f, "agent turn {active_turn_id} is already active")
            }
            TurnError::NotActive => f.write_str("no agent turn is currently active"),
            TurnError::TurnMismatch { expected, actual } => {
                write!(f, "active agent turn is {expected}, got {actual}")
            }
            TurnError::Invalid(msg) => f.write_str(msg),
            TurnError::CommandFailed(err) => err.fmt(f),
        }
    }
}

impl std::error::Error for TurnError {}

struct ActiveAgentTurn {
    turn_id: String,
    summary: String,
    baseline_project: Project,
    command_count: usize,
}

/// The state before one recorded step, and the gesture/turn it belonged to.
struct Snapshot {
    before: Project,
    /// Set while the gesture that produced this step may still continue;
    /// cleared by [`Editor::end_gesture`] or by any step of another kind.
    gesture: Option<String>,
    turn: Option<TurnMeta>,
}

struct RedoEntry {
    after: Project,
    turn: Option<TurnMeta>,
}

/// One editing session: the project, the id mint that keeps its ids unique,
/// and the undo/redo stacks. This is the object a host holds per open
/// project; everything else in the crate is reachable through it.
pub struct Editor {
    project: Project,
    mint: IdMint,
    revision: u64,
    active_turn: Option<ActiveAgentTurn>,
    /// Oldest snapshot at the front: overflowing the depth cap evicts from
    /// the front in constant time, where a Vec would shuffle the whole stack.
    undo: VecDeque<Snapshot>,
    redo: Vec<RedoEntry>,
}

impl Editor {
    /// A fresh, empty project.
    pub fn new() -> Self {
        Self::with_video(crate::model::VideoSettings::default())
    }

    /// A fresh editor whose first timeline renders to `video`.
    pub fn with_video(video: crate::model::VideoSettings) -> Self {
        Self {
            project: Project::with_video(video),
            mint: IdMint::default(),
            revision: 0,
            active_turn: None,
            undo: VecDeque::new(),
            redo: Vec::new(),
        }
    }

    /// Restores a project from a document, adopting every id it uses so the
    /// mint can never re-issue one. Returns None when the document holds
    /// nothing recognisable.
    pub fn from_document(document: &Value) -> Option<Self> {
        let project = from_document(document)?;
        let mut mint = IdMint::default();
        mint.adopt_project(&project);
        Some(Self {
            project,
            mint,
            revision: 0,
            active_turn: None,
            undo: VecDeque::new(),
            redo: Vec::new(),
        })
    }

    /// Rewrites the picture links `upgrade` changes - one to a retired
    /// effect, read as a link to the effect that stands in for it - as the
    /// document is read, before any edit: not a step to undo, since it is
    /// what the document means now. Returns whether any link changed.
    pub fn upgrade_links(&mut self, mut upgrade: impl FnMut(&mut AppliedFilter) -> bool) -> bool {
        use std::sync::Arc;
        let mut changed = false;
        for timeline in &mut self.project.timelines {
            for index in 0..timeline.clips.len() {
                let mut links = timeline.clips[index].video_effects.clone();
                let mut any = false;
                for link in &mut links {
                    any |= upgrade(link);
                }
                if any {
                    let timeline = Arc::make_mut(timeline);
                    Arc::make_mut(&mut timeline.clips[index]).video_effects = links;
                    changed = true;
                }
            }
        }
        changed
    }

    /// Takes off the clip fields earlier versions wrote and this one no
    /// longer reads - 0.2.4's `reverse` flag and its preset animations -
    /// as the document is read, the way [`Editor::upgrade_links`] does: not
    /// a step to undo. They rode along unread, so a reversed clip played
    /// forwards and an animated one sat still with nothing said (audit
    /// 2026-09-28, #5). Returns the names of the clips that had each, so
    /// the open can say which; the next save makes it so.
    pub fn drop_retired_fields(&mut self) -> RetiredFields {
        use std::sync::Arc;
        const ANIMATIONS: [&str; 4] = [
            "animationIn",
            "animationOut",
            "animationCombo",
            "animationLoop",
        ];
        let mut found = RetiredFields::default();
        for timeline in &mut self.project.timelines {
            for index in 0..timeline.clips.len() {
                let extra = &timeline.clips[index].extra;
                let reversed = extra.get("reverse").and_then(|v| v.as_bool()) == Some(true);
                let animated = ANIMATIONS
                    .iter()
                    .any(|key| extra.get(*key).is_some_and(|value| !value.is_null()));
                let any = extra.contains_key("reverse")
                    || ANIMATIONS.iter().any(|key| extra.contains_key(*key));
                if !any {
                    continue;
                }
                let name = timeline.clips[index].name.clone();
                if reversed && !found.reversed.contains(&name) {
                    found.reversed.push(name.clone());
                }
                if animated && !found.animated.contains(&name) {
                    found.animated.push(name);
                }
                let timeline = Arc::make_mut(timeline);
                let clip = Arc::make_mut(&mut timeline.clips[index]);
                clip.extra.remove("reverse");
                for key in ANIMATIONS {
                    clip.extra.remove(key);
                }
            }
        }
        found
    }

    /// The current state, read-only: all mutation goes through
    /// [`Editor::apply`] so nothing can change without being undoable.
    pub fn project(&self) -> &Project {
        &self.project
    }

    /// The project, writable around the undo stack: for tests that need a
    /// state no command makes any more, such as the stacked clips an older
    /// document can hold.
    #[cfg(test)]
    pub(crate) fn project_mut(&mut self) -> &mut Project {
        &mut self.project
    }

    /// Applies one command, recording the state before it for undo.
    ///
    /// A command that fails leaves the project and history untouched, and
    /// the snapshot is only kept when the command reports it actually
    /// changed something ([`Outcome::applied`]), so undo never replays a
    /// no-op - a missing id, a value already in place.
    pub fn apply(&mut self, command: Command) -> Result<Outcome, CommandError> {
        self.apply_within(None, command)
    }

    /// [`Editor::apply`] as one move of a gesture.
    ///
    /// The first command naming a gesture records a step as usual; every
    /// later command naming the same gesture, with no other step recorded
    /// in between, folds into that step, so undo lands where the gesture
    /// began. Commands that set absolute values (every inspector knob) are
    /// the ones this is for. `None` is a step of its own, and ends any
    /// gesture in progress.
    pub fn apply_within(
        &mut self,
        gesture: Option<&str>,
        command: Command,
    ) -> Result<Outcome, CommandError> {
        if command.is_view_state() {
            return apply(&mut self.project, &mut self.mint, command);
        }
        let before = self.project.clone();
        let outcome = apply(&mut self.project, &mut self.mint, command)?;
        if !outcome.applied {
            return Ok(outcome);
        }
        self.tidy_touched(&before);
        self.follow_first_hdr(&before);
        let continues = match (gesture, self.undo.back()) {
            (Some(gesture), Some(last)) => last.gesture.as_deref() == Some(gesture),
            _ => false,
        };
        if !continues {
            self.undo.push_back(Snapshot {
                before,
                gesture: gesture.map(str::to_owned),
                turn: None,
            });
            if self.undo.len() > UNDO_DEPTH {
                self.undo.pop_front();
            }
        }
        self.revision += 1;
        self.redo.clear();
        Ok(outcome)
    }

    /// Current monotonic document revision. Increments only on `DocumentState` mutations.
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Active uncommitted turn identifier, if any.
    pub fn active_turn_id(&self) -> Option<&str> {
        self.active_turn.as_ref().map(|t| t.turn_id.as_str())
    }

    /// Metadata of the latest undoable `AgentTurn`, if it sits at the top of the Undo stack.
    pub fn top_undo_turn(&self) -> Option<&TurnMeta> {
        self.undo.back().and_then(|s| s.turn.as_ref())
    }

    /// Opens a transactional `AgentTurn` capturing the current `Project` baseline.
    pub fn begin_agent_turn(&mut self, turn_id: &str, summary: &str) -> Result<(), TurnError> {
        if turn_id.trim().is_empty() || turn_id.len() > 64 {
            return Err(TurnError::Invalid("turn_id must be 1..=64 bytes".into()));
        }
        let summary_trimmed = summary.trim();
        if summary_trimmed.is_empty() {
            return Err(TurnError::Invalid("turn summary must not be empty".into()));
        }
        if let Some(active) = &self.active_turn {
            return Err(TurnError::AlreadyActive {
                active_turn_id: active.turn_id.clone(),
            });
        }
        self.end_gesture();
        self.active_turn = Some(ActiveAgentTurn {
            turn_id: turn_id.to_owned(),
            summary: summary_trimmed.chars().take(160).collect(),
            baseline_project: self.project.clone(),
            command_count: 0,
        });
        Ok(())
    }

    /// Executes a command inside the active `AgentTurn` without pushing an Undo frame yet.
    pub fn apply_in_turn(
        &mut self,
        turn_id: &str,
        command: Command,
    ) -> Result<Outcome, TurnError> {
        let Some(active) = &self.active_turn else {
            return Err(TurnError::NotActive);
        };
        if active.turn_id != turn_id {
            return Err(TurnError::TurnMismatch {
                expected: active.turn_id.clone(),
                actual: turn_id.to_owned(),
            });
        }
        if command.is_view_state() {
            return apply(&mut self.project, &mut self.mint, command)
                .map_err(TurnError::CommandFailed);
        }
        let before_step = self.project.clone();
        let outcome =
            apply(&mut self.project, &mut self.mint, command).map_err(TurnError::CommandFailed)?;
        if outcome.applied {
            self.tidy_touched(&before_step);
            self.follow_first_hdr(&before_step);
            if let Some(active) = self.active_turn.as_mut() {
                active.command_count += 1;
            }
        }
        Ok(outcome)
    }

    /// Commits the active `AgentTurn` as 1 unified Undo/Redo step.
    pub fn commit_agent_turn(&mut self, turn_id: &str) -> Result<TurnCommit, TurnError> {
        let Some(active) = self.active_turn.as_ref() else {
            return Err(TurnError::NotActive);
        };
        if active.turn_id != turn_id {
            return Err(TurnError::TurnMismatch {
                expected: active.turn_id.clone(),
                actual: turn_id.to_owned(),
            });
        }
        let active = self.active_turn.take().expect("checked");
        let affected_clip_ids = touched_clip_ids(&active.baseline_project, &self.project);
        let changed = active.command_count > 0 && self.project != active.baseline_project;
        if changed {
            self.revision += 1;
            let meta = TurnMeta {
                turn_id: active.turn_id.clone(),
                summary: active.summary.clone(),
                affected_clip_ids: affected_clip_ids.clone(),
                revision: self.revision,
            };
            self.undo.push_back(Snapshot {
                before: active.baseline_project,
                gesture: None,
                turn: Some(meta),
            });
            if self.undo.len() > UNDO_DEPTH {
                self.undo.pop_front();
            }
            self.redo.clear();
        }
        Ok(TurnCommit {
            turn_id: active.turn_id,
            summary: active.summary,
            revision: self.revision,
            affected_clip_ids,
            pushed_undo_step: changed,
        })
    }

    /// Rolls back the active uncommitted `AgentTurn`, restoring the exact pre-turn baseline.
    pub fn rollback_agent_turn(&mut self, turn_id: &str) -> Result<u64, TurnError> {
        let Some(active) = self.active_turn.as_ref() else {
            return Err(TurnError::NotActive);
        };
        if active.turn_id != turn_id {
            return Err(TurnError::TurnMismatch {
                expected: active.turn_id.clone(),
                actual: turn_id.to_owned(),
            });
        }
        let active = self.active_turn.take().expect("checked");
        self.project = active.baseline_project;
        Ok(self.revision)
    }

    /// Runs [`Clip::tidy`] over every clip the command wrote, so the clamps
    /// live in one place and a document is the same on screen as it is
    /// after a save and a reopen (audit 2026-09-23, #13). Only a clip
    /// whose `Arc` the command replaced is looked at: the rest are still
    /// the snapshot's, and were tidy already.
    fn tidy_touched(&mut self, before: &Project) {
        use std::collections::HashSet;
        use std::sync::Arc;
        let previous: std::collections::HashMap<&str, &Arc<crate::model::Timeline>> = before
            .timelines
            .iter()
            .map(|timeline| (timeline.id.as_str(), timeline))
            .collect();
        for timeline in &mut self.project.timelines {
            let old = previous.get(timeline.id.as_str()).copied();
            if old.is_some_and(|old| Arc::ptr_eq(old, timeline)) {
                continue;
            }
            let kept: HashSet<*const Clip> = old
                .map(|old| old.clips.iter().map(Arc::as_ptr).collect())
                .unwrap_or_default();
            let timeline = Arc::make_mut(timeline);
            for clip in &mut timeline.clips {
                if kept.contains(&Arc::as_ptr(clip)) {
                    continue;
                }
                let tidied = (**clip).clone().tidy();
                if tidied != **clip {
                    *clip = Arc::new(tidied);
                }
            }
        }
    }

    /// Makes an SDR timeline HLG when the command put its first HDR clip on
    /// it - a clip of a file recorded in HLG or PQ, where before it had
    /// none - in the same step, so an undo takes both back. A timeline set
    /// back to SDR with HDR clips already on it stays SDR (decided 26 Sept:
    /// the Modify sheet can change it back), and only a timeline the
    /// command wrote, and did not make, is looked at.
    fn follow_first_hdr(&mut self, before: &Project) {
        use std::collections::HashSet;
        use std::sync::Arc;
        let hdr = |project: &Project| -> HashSet<String> {
            project
                .media
                .iter()
                .filter(|media| media.color_space.is_hdr())
                .map(|media| media.id.clone())
                .collect()
        };
        let now = hdr(&self.project);
        if now.is_empty() {
            return;
        }
        let then = hdr(before);
        let previous: std::collections::HashMap<&str, &Arc<crate::model::Timeline>> = before
            .timelines
            .iter()
            .map(|timeline| (timeline.id.as_str(), timeline))
            .collect();
        for timeline in &mut self.project.timelines {
            if timeline.video.color_space.is_hdr() {
                continue;
            }
            // A timeline the command made keeps the colour it was made
            // with - a copy of one set back to SDR stays SDR.
            let Some(old) = previous.get(timeline.id.as_str()).copied() else {
                continue;
            };
            if Arc::ptr_eq(old, timeline) {
                continue;
            }
            let had = old.clips.iter().any(|clip| then.contains(&clip.media_id));
            let has = timeline
                .clips
                .iter()
                .any(|clip| now.contains(&clip.media_id));
            if has && !had {
                Arc::make_mut(timeline).video.color_space = crate::model::ColorSpace::Hlg;
            }
        }
    }

    /// Ends the gesture in progress, if any: the next command naming it
    /// starts a new step rather than folding into the last one. Called when
    /// the pointer goes up, or when enough time has passed that a second
    /// drag of the same knob is a second edit.
    pub fn end_gesture(&mut self) {
        if let Some(last) = self.undo.back_mut() {
            last.gesture = None;
        }
    }

    /// Steps back one edit. Returns whether anything changed.
    pub fn undo(&mut self) -> bool {
        match self.undo.pop_back() {
            Some(previous) => {
                let after = std::mem::replace(&mut self.project, previous.before);
                self.redo.push(RedoEntry {
                    after,
                    turn: previous.turn,
                });
                self.revision += 1;
                true
            }
            None => false,
        }
    }

    /// Steps forward again. Returns whether anything changed.
    pub fn redo(&mut self) -> bool {
        match self.redo.pop() {
            Some(next) => {
                let before = std::mem::replace(&mut self.project, next.after);
                self.undo.push_back(Snapshot {
                    before,
                    gesture: None,
                    turn: next.turn,
                });
                self.revision += 1;
                true
            }
            None => false,
        }
    }

    /// Whether [`Editor::undo`] would do anything - what the UI's undo
    /// button greys out on.
    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    /// Whether [`Editor::redo`] would do anything; the redo button's twin
    /// of [`Editor::can_undo`].
    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    /// The full document for saving.
    pub fn to_document(&self, settings: &DocumentSettings) -> Value {
        to_document(settings, &self.project)
    }
}

impl Default for Editor {
    fn default() -> Self {
        Self::new()
    }
}

/// The clips [`Editor::drop_retired_fields`] found, by name, each once.
/// Retired fields struct.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RetiredFields {
    /// Clips an earlier version played backwards, which now play forwards.
    pub reversed: Vec<String>,
    /// Clips an earlier version moved with a preset animation.
    pub animated: Vec<String>,
}

/// Returns deduplicated IDs of clips added or modified between `before` and `after`.
pub fn touched_clip_ids(before: &Project, after: &Project) -> Vec<String> {
    use std::collections::{HashMap, HashSet};
    use std::sync::Arc;
    let old_clips: HashMap<&str, *const Clip> = before
        .timelines
        .iter()
        .flat_map(|tl| tl.clips.iter())
        .map(|c| (c.id.as_str(), Arc::as_ptr(c)))
        .collect();
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for tl in &after.timelines {
        for clip in &tl.clips {
            let ptr = Arc::as_ptr(clip);
            let changed = old_clips
                .get(clip.id.as_str())
                .is_none_or(|old_ptr| *old_ptr != ptr);
            if changed && seen.insert(clip.id.clone()) {
                out.push(clip.id.clone());
            }
        }
    }
    out
}

#[cfg(test)]
mod agent_turn_tests {
    use super::*;
    use crate::commands::{Command, NewMedia};
    use crate::model::MediaKind;

    #[test]
    fn agent_turn_groups_multiple_edits_into_single_undo_redo_and_supports_rollback() {
        let mut editor = Editor::new();
        let media_id = editor
            .apply(Command::AddMedia {
                item: NewMedia {
                    path: "/tmp/sample.mp4".into(),
                    name: "sample.mp4".into(),
                    duration: Some(10.0),
                    kind: MediaKind::Video,
                    width: Some(1920),
                    height: Some(1080),
                    frame_rate: Some(30.0),
                    frame_rate_fraction: Some("30/1".into()),
                    video_codec: Some("h264".into()),
                    audio_codec: Some("aac".into()),
                    has_audio: true,
                    audio_tracks: Vec::new(),
                    origin: None,
                    color_space: Default::default(),
                },
            })
            .expect("add media")
            .created_id
            .expect("media id");
        let track_id = editor.project().active().tracks[0].id.clone();

        // 1. Open transactional AgentTurn and apply 3 commands.
        editor
            .begin_agent_turn("turn-1", "Rough cut test")
            .expect("begin turn");
        let c1 = editor
            .apply_in_turn(
                "turn-1",
                Command::AddClip {
                    media_id: media_id.clone(),
                    track_id: track_id.clone(),
                    start: 0.0,
                    ripple: false,
                },
            )
            .expect("clip 1")
            .created_id
            .expect("id1");
        let c2 = editor
            .apply_in_turn(
                "turn-1",
                Command::AddClip {
                    media_id: media_id.clone(),
                    track_id: track_id.clone(),
                    start: 2.0,
                    ripple: false,
                },
            )
            .expect("clip 2")
            .created_id
            .expect("id2");
        editor
            .apply_in_turn(
                "turn-1",
                Command::MoveClips {
                    moves: vec![crate::commands::ClipMove {
                        clip_id: c2.clone(),
                        start: 15.0,
                        track_id: track_id.clone(),
                    }],
                },
            )
            .expect("move clip 2");

        let commit = editor.commit_agent_turn("turn-1").expect("commit turn");
        assert_eq!(commit.turn_id, "turn-1");
        assert!(commit.pushed_undo_step);
        assert!(commit.affected_clip_ids.contains(&c1));
        assert!(commit.affected_clip_ids.contains(&c2));
        assert_eq!(editor.project().active().clips.len(), 2);

        // Single undo reverts the entire 3-command turn back to 0 clips.
        assert!(editor.undo());
        assert_eq!(editor.project().active().clips.len(), 0);
        // Single redo reapplies all 3 edits together.
        assert!(editor.redo());
        assert_eq!(editor.project().active().clips.len(), 2);
        assert_eq!(
            editor.project().active().clip(&c2).expect("c2").start,
            15.0
        );

        // 2. Rollback discards uncommitted edits cleanly.
        editor
            .begin_agent_turn("turn-2", "Aborted turn")
            .expect("begin turn 2");
        editor
            .apply_in_turn(
                "turn-2",
                Command::AddClip {
                    media_id,
                    track_id,
                    start: 10.0,
                    ripple: false,
                },
            )
            .expect("temp clip");
        assert_eq!(editor.project().active().clips.len(), 3);
        editor.rollback_agent_turn("turn-2").expect("rollback");
        assert_eq!(editor.project().active().clips.len(), 2);
        // Top undo step is still turn-1, not turn-2.
        assert_eq!(
            editor.top_undo_turn().map(|m| m.turn_id.as_str()),
            Some("turn-1")
        );
    }
}
