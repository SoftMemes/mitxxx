#!/usr/bin/env python3
"""
CLI for the MITx unofficial client.

UNOFFICIAL — not affiliated with MIT or MITx.
"""
import json
import sys
import getpass

import click

try:
    from client import MITxClient, AuthError, SESSION_FILE
except ImportError:
    # Allow running from outside the directory
    import os
    sys.path.insert(0, os.path.dirname(__file__))
    from client import MITxClient, AuthError, SESSION_FILE


def get_client(require_auth: bool = True) -> MITxClient:
    c = MITxClient()
    if require_auth:
        if not c.load_session():
            click.echo("No saved session. Run: python cli.py login", err=True)
            sys.exit(1)
    return c


@click.group()
def cli():
    """MITx unofficial CLI — UNOFFICIAL, not affiliated with MIT."""
    pass


@cli.command()
@click.option("--email", prompt="Email", help="MITx account email")
@click.option("--password", default=None, help="MITx account password (prompted if omitted)")
def login(email, password):
    """Login to MITx and save session."""
    if not password:
        password = getpass.getpass("Password: ")
    c = get_client(require_auth=False)
    try:
        user = c.login(email, password)
        click.echo(f"Logged in as {user['username']} ({user['email']})")
        click.echo(f"Session saved to {SESSION_FILE}")
    except AuthError as e:
        click.echo(f"Login failed: {e}", err=True)
        sys.exit(1)


@cli.command()
def logout():
    """Delete saved session."""
    if SESSION_FILE.exists():
        SESSION_FILE.unlink()
        click.echo("Session deleted.")
    else:
        click.echo("No session found.")


@cli.command()
def whoami():
    """Show current authenticated user."""
    c = get_client()
    user = c.current_user()
    click.echo(json.dumps(user, indent=2))


@cli.command()
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
def enrollments(as_json):
    """List enrolled courses."""
    c = get_client()
    data = c.enrollments()
    if as_json:
        click.echo(json.dumps(data, indent=2))
        return
    if not data:
        click.echo("No enrollments found.")
        return
    for enr in data:
        run = enr.get("run", {})
        click.echo(f"\n  {run.get('title', '?')}")
        click.echo(f"    courseware_id : {run.get('courseware_id', '?')}")
        click.echo(f"    mode          : {enr.get('enrollment_mode', '?')}")
        click.echo(f"    start         : {run.get('start_date', '?')}")
        click.echo(f"    end           : {run.get('end_date', '?')}")
        click.echo(f"    url           : {run.get('courseware_url', '?')}")


@cli.command()
@click.argument("course_id")
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
def outline(course_id, as_json):
    """Show course outline (sections and sequences).

    COURSE_ID: e.g. course-v1:MITxT+24.09x+1T2025
    """
    c = get_client()
    data = c.course_outline(course_id)
    if as_json:
        click.echo(json.dumps(data, indent=2))
        return
    click.echo(f"\nCourse: {data.get('title', course_id)}")
    click.echo(f"Start:  {data.get('course_start', '?')}  End: {data.get('course_end', '?')}\n")
    for section in data.get("outline", {}).get("sections", []):
        click.echo(f"  [{section['title']}]")
        click.echo(f"    id: {section['id']}")
        for seq_id in section.get("sequence_ids", []):
            click.echo(f"    seq: {seq_id}")
        click.echo()


@cli.command()
@click.argument("block_id")
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
def sequence(block_id, as_json):
    """Show items in a sequence (verticals).

    BLOCK_ID: e.g. block-v1:MITxT+...+type@sequential+block@...
    """
    c = get_client()
    data = c.sequence(block_id)
    if as_json:
        click.echo(json.dumps(data, indent=2))
        return
    items = data.get("items", [])
    click.echo(f"\n{len(items)} items in sequence:\n")
    for item in items:
        click.echo(f"  [{item.get('type', '?'):8}] {item.get('page_title', '?')}")
        click.echo(f"           id: {item.get('id', '?')}")


@cli.command()
@click.argument("block_id")
@click.option("--show-html", is_flag=True, help="Print raw xblock HTML")
@click.option("--json", "as_json", is_flag=True, help="Output video metadata as JSON")
def xblock(block_id, show_html, as_json):
    """Get xblock content and extract video metadata.

    BLOCK_ID: e.g. block-v1:MITxT+...+type@vertical+block@...
    """
    c = get_client()
    html = c.xblock_html(block_id)
    if show_html:
        click.echo(html)
        return
    videos = c.extract_video_metadata(html)
    if not videos:
        click.echo("No video blocks found in this xblock.")
        return
    if as_json:
        click.echo(json.dumps(videos, indent=2))
        return
    click.echo(f"\n{len(videos)} video block(s) found:\n")
    for i, v in enumerate(videos):
        click.echo(f"  Video {i + 1}:")
        click.echo(f"    duration : {v.get('duration', '?')}s")
        click.echo(f"    sources  :")
        for src in v.get("sources", []):
            click.echo(f"      {src}")
        langs = v.get("transcriptLanguages", {})
        if langs:
            click.echo(f"    transcripts: {', '.join(langs.keys())}")


@cli.command("download-video")
@click.argument("block_id")
@click.option("--output", "-o", default="./videos", show_default=True,
              help="Output directory for downloaded videos")
@click.option("--hls", is_flag=True, help="Prefer HLS (.m3u8) over MP4")
def download_video(block_id, output, hls):
    """Download video(s) from a vertical xblock.

    BLOCK_ID: e.g. block-v1:MITxT+...+type@vertical+block@...
    """
    c = get_client()

    def progress(downloaded, total, filename):
        if total:
            pct = downloaded / total * 100
            click.echo(f"\r  {filename}: {pct:.1f}% ({downloaded}/{total} bytes)", nl=False)
        else:
            click.echo(f"\r  {filename}: {downloaded} bytes", nl=False)

    click.echo(f"Fetching xblock {block_id}...")
    paths = c.download_video(block_id, output_dir=output, prefer_hls=hls,
                             progress_callback=progress)
    click.echo()
    if not paths:
        click.echo("No videos found to download.")
        return
    click.echo(f"\nDownloaded {len(paths)} file(s):")
    for p in paths:
        click.echo(f"  {p}")


@cli.command()
@click.argument("course_id")
@click.argument("video_block_id")
@click.option("--lang", default="en", show_default=True, help="Transcript language code")
@click.option("--output", "-o", default=None, help="Save to file instead of printing")
def transcript(course_id, video_block_id, lang, output):
    """Download transcript for a video block.

    COURSE_ID: e.g. course-v1:MITxT+24.09x+1T2025
    VIDEO_BLOCK_ID: e.g. block-v1:MITxT+...+type@video+block@...
    """
    c = get_client()
    text = c.transcript(course_id, video_block_id, lang=lang)
    if output:
        with open(output, "w") as f:
            f.write(text)
        click.echo(f"Transcript saved to {output}")
    else:
        click.echo(text)


if __name__ == "__main__":
    cli()
