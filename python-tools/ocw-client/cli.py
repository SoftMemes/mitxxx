#!/usr/bin/env python3
"""
CLI for the OCW unofficial client.

UNOFFICIAL — not affiliated with MIT or MIT OpenCourseWare.
"""
from __future__ import annotations

import json
import os
import sys

import click

try:
    from client import (
        OcwClient,
        build_course_from_fixtures,
        course_to_dict,
        match_resources_to_lectures,
        parse_course_home,
        parse_lecture_notes_page,
        parse_lecture_page,
        parse_video_gallery,
    )
except ImportError:
    sys.path.insert(0, os.path.dirname(__file__))
    from client import (
        OcwClient,
        build_course_from_fixtures,
        course_to_dict,
        match_resources_to_lectures,
        parse_course_home,
        parse_lecture_notes_page,
        parse_lecture_page,
        parse_video_gallery,
    )


def _load_course(slug: str, fixture_dir: str | None):
    if fixture_dir:
        return build_course_from_fixtures(slug, fixture_dir)
    return OcwClient().get_course(slug)


@click.group()
def cli():
    """OCW unofficial CLI — UNOFFICIAL, not affiliated with MIT."""
    pass


@cli.command()
@click.argument("slug")
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
@click.option(
    "--fixture-dir",
    default=None,
    help="Load from a fixture directory instead of HTTP (offline mode)",
)
def course(slug: str, as_json: bool, fixture_dir: str | None):
    """Show a course's outline + lecture list + resource counts.

    SLUG: e.g. 9-13-the-human-brain-spring-2019
    """
    c = _load_course(slug, fixture_dir)
    if as_json:
        click.echo(json.dumps(course_to_dict(c), indent=2, default=str))
        return
    click.echo(f"\n{c.title}  ({c.course_number})")
    click.echo(f"  id: {c.id}")
    if c.description:
        click.echo(f"  {c.description[:200]}{'…' if len(c.description) > 200 else ''}")
    click.echo()
    for s in c.sections:
        click.echo(f"  [{s.title}]  ({len(s.lectures)} lectures)")
        with_video = sum(1 for l in s.lectures if l.mp4_url)
        with_notes = sum(1 for l in s.lectures if l.resources)
        click.echo(f"    {with_video}/{len(s.lectures)} have a video download link")
        click.echo(f"    {with_notes}/{len(s.lectures)} have matched resources")
    if c.orphan_resources:
        click.echo(f"\n  Orphan resources (course-level): {len(c.orphan_resources)}")
        for r in c.orphan_resources:
            click.echo(f"    - [{r.type.value}] {r.title}")


@cli.command()
@click.argument("slug")
@click.argument("lecture_slug")
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
@click.option("--fixture-dir", default=None, help="Load from a fixture directory (offline mode)")
def lecture(slug: str, lecture_slug: str, as_json: bool, fixture_dir: str | None):
    """Show a single lecture: title + mp4 URL + matched resources.

    SLUG:         e.g. 9-13-the-human-brain-spring-2019
    LECTURE_SLUG: e.g. lecture-1-introduction
    """
    c = _load_course(slug, fixture_dir)
    found = None
    for sec in c.sections:
        for l in sec.lectures:
            if l.slug == lecture_slug:
                found = l
                break
        if found:
            break
    if not found:
        click.echo(f"Lecture not found: {lecture_slug}", err=True)
        sys.exit(1)
    if as_json:
        from dataclasses import asdict
        click.echo(json.dumps(asdict(found), indent=2, default=str))
        return
    click.echo(f"\n{found.title}")
    click.echo(f"  id:       {found.id}")
    click.echo(f"  slug:     {found.slug}")
    click.echo(f"  mp4:      {found.mp4_url or '(no video download link)'}")
    if found.resources:
        click.echo(f"  resources ({len(found.resources)}):")
        for r in found.resources:
            click.echo(f"    - [{r.type.value}] {r.title}")
            click.echo(f"      {r.url}")
    else:
        click.echo("  resources: (none matched)")


@cli.command()
@click.argument("slug")
@click.option("--json", "as_json", is_flag=True, help="Output raw JSON")
@click.option("--fixture-dir", default=None, help="Load from a fixture directory (offline mode)")
def resources(slug: str, as_json: bool, fixture_dir: str | None):
    """List all lecture-notes / lecture-slides for a course with their matched lecture (or orphan)."""
    c = _load_course(slug, fixture_dir)
    all_rows: list[tuple[str, str, str, str]] = []
    for sec in c.sections:
        for l in sec.lectures:
            for r in l.resources:
                all_rows.append((r.type.value, r.title, l.slug, r.url))
    for r in c.orphan_resources:
        all_rows.append((r.type.value, r.title, "(orphan)", r.url))

    if as_json:
        click.echo(json.dumps([
            {"type": t, "title": title, "lecture_slug": lec, "url": url}
            for (t, title, lec, url) in all_rows
        ], indent=2))
        return

    if not all_rows:
        click.echo("(no resources found)")
        return
    for t, title, lec, url in all_rows:
        click.echo(f"  [{t}] {title[:60]:60s}  ->  {lec}")
        click.echo(f"       {url}")


@cli.command()
@click.argument("slug")
@click.option("--fixture-dir", default=None, help="Load from a fixture directory (offline mode)")
def match(slug: str, fixture_dir: str | None):
    """Debug: show the resource-to-lecture matching result."""
    c = _load_course(slug, fixture_dir)
    total_lectures = sum(len(s.lectures) for s in c.sections)
    total_resources = sum(len(l.resources) for s in c.sections for l in s.lectures) + len(c.orphan_resources)
    matched = total_resources - len(c.orphan_resources)

    click.echo(f"\n{c.title}  ({c.course_number})")
    click.echo(f"  lectures: {total_lectures}")
    click.echo(f"  resources total: {total_resources}  matched: {matched}  orphaned: {len(c.orphan_resources)}")
    click.echo()
    for s in c.sections:
        for l in s.lectures:
            status = "no notes" if not l.resources else f"{len(l.resources)} matched"
            click.echo(f"  {l.title[:55]:55s}  [{status}]")
    if c.orphan_resources:
        click.echo("\n  orphans:")
        for r in c.orphan_resources:
            click.echo(f"    - [{r.type.value}] {r.title}")


if __name__ == "__main__":
    cli()
