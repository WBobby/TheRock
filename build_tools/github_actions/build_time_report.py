#!/usr/bin/env python3
"""
Build time report generator for TheRock CI builds.

Parses build logs with BEGIN/END timestamps and generates an HTML report.
"""

import re
from datetime import datetime
from pathlib import Path


def parse_build_log(log_path):
    """Parse a single build log file to extract timing information."""
    try:
        with open(log_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        begin_match = re.search(r'^BEGIN\t([\d.]+)', content, re.MULTILINE)
        end_match = re.search(r'^END\t([\d.]+)\t([\d.]+)\t(\d+)', content, re.MULTILINE)
        
        if begin_match and end_match:
            return {
                'start': float(begin_match.group(1)),
                'end': float(end_match.group(1)),
                'duration': float(end_match.group(2)),
                'success': int(end_match.group(3)) == 0
            }
    except Exception:
        pass
    return None


def collect_build_times(log_dir: Path):
    """Collect build times from all *_build.log files in log directory."""
    components = {}
    
    if not log_dir.exists():
        return components
    
    for log_file in log_dir.glob("*_build.log"):
        component = log_file.stem.replace("_build", "")
        timing = parse_build_log(log_file)
        if timing:
            components[component] = timing
    
    return components


def generate_html_report(components, output_file: Path):
    """Generate HTML report from collected build time data."""
    if not components:
        return False
    
    # Sort by duration
    sorted_components = sorted(
        components.items(), 
        key=lambda x: x[1]['duration'], 
        reverse=True
    )
    
    # Calculate statistics
    total_time = sum(c['duration'] for c in components.values())
    max_time = sorted_components[0][1]['duration'] if sorted_components else 1
    
    # Generate HTML table rows
    rows = []
    for name, data in sorted_components:
        duration = data['duration']
        status = '✅' if data['success'] else '❌'
        bar_width = int((duration / max_time) * 100)
        
        rows.append(f"""
        <tr>
            <td style="text-align: left; padding: 8px;">{name}</td>
            <td style="padding: 8px;"><strong>{duration:.1f}s</strong></td>
            <td style="padding: 8px; width: 200px;">
                <div style="background: #e0e0e0; border-radius: 3px; overflow: hidden; height: 20px;">
                    <div style="background: linear-gradient(90deg, #4CAF50, #45a049); 
                                width: {bar_width}%; height: 100%; min-width: 2px;"></div>
                </div>
            </td>
            <td style="padding: 8px; text-align: center;">{status}</td>
        </tr>
        """)
    
    # Generate complete HTML
    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>TheRock Build Times</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               margin: 20px; background: #f5f5f5; }}
        .container {{ max-width: 1000px; margin: 0 auto; background: white;
                      padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
        h1 {{ color: #333; border-bottom: 3px solid #4CAF50; padding-bottom: 10px; }}
        .summary {{ background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    color: white; padding: 20px; border-radius: 8px; margin: 20px 0;
                    display: flex; justify-content: space-around; }}
        .summary div {{ text-align: center; }}
        .summary .label {{ font-size: 14px; opacity: 0.9; }}
        .summary .value {{ font-size: 32px; font-weight: bold; margin-top: 5px; }}
        table {{ width: 100%; border-collapse: collapse; margin-top: 20px; }}
        th, td {{ padding: 12px; border-bottom: 1px solid #e0e0e0; }}
        th {{ background: #f5f5f5; font-weight: 600; text-align: left; position: sticky; top: 0; }}
        tr:hover {{ background: #f9f9f9; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 TheRock Build Times</h1>
        <p>Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}</p>
        
        <div class="summary">
            <div>
                <div class="label">Total Build Time</div>
                <div class="value">{int(total_time)}s</div>
            </div>
            <div>
                <div class="label">Components Built</div>
                <div class="value">{len(components)}</div>
            </div>
        </div>
        
        <table>
            <thead>
                <tr>
                    <th>Component</th>
                    <th style="text-align: center;">Build Time</th>
                    <th style="text-align: center;">Progress</th>
                    <th style="text-align: center;">Status</th>
                </tr>
            </thead>
            <tbody>
                {''.join(rows)}
            </tbody>
        </table>
    </div>
</body>
</html>"""
    
    output_file.write_text(html)
    return True


def generate_build_times_report(build_dir: Path):
    """
    Main entry point: generate build times report from build directory logs.
    
    Returns:
        bool: True if report was generated successfully, False otherwise.
    """
    log_dir = build_dir / "logs"
    output_file = log_dir / "build_times.html"
    
    components = collect_build_times(log_dir)
    if not components:
        return False
    
    return generate_html_report(components, output_file)


if __name__ == "__main__":
    import sys
    
    build_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build")
    
    if generate_build_times_report(build_dir):
        print(f"✓ Generated build times report: {build_dir}/logs/build_times.html")
    else:
        print("✗ No build timing data found", file=sys.stderr)
        sys.exit(1)

