# ffmpeg

`ffmpeg` here is FFmpeg 9.1 (see `VERSION`), built by `scripts/build-ffmpeg.sh` from the
source at https://ffmpeg.org/releases/. It is licensed under the GNU Lesser General Public
License, version 2.1 or later (no GPL or non-free parts are enabled); the source and the exact
configure options are in that script. Editroom runs it as a separate program, only to rewrap or
convert video and audio files that macOS can't open itself.

The build copies it into the app (Contents/MacOS/ffmpeg) and signs it with the app's identity.
