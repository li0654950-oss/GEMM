#!/usr/bin/env python3
"""
gen_inst.py - Auto-generate SystemVerilog module instantiation from .sv files
Usage: python3 gen_inst.py <module_name> <sv_file>
"""
import sys, re, os

def extract_ports(sv_path):
    with open(sv_path, 'r') as f:
        text = f.read()
    # Find module declaration
    m = re.search(r'module\s+\w+\s*#?\s*\([^\)]*\)\s*\((.*?)\);', text, re.DOTALL)
    if not m:
        return []
    body = m.group(1)
    ports = []
    # Match each port declaration: direction [width] name,
    # Handle multiline
    pattern = r'(input|output)\s+(?:reg\s+)?(?:wire\s+)?((?:\[.*?\])?)\s*([A-Za-z_][A-Za-z0-9_]*)\s*'
    for line in body.split('\n'):
        line = line.strip().rstrip(',')
        if not line or line.startswith('//') or line.startswith('/*'):
            continue
        # Try to match direction + optional width + name
        m2 = re.search(pattern, line)
        if m2:
            dir_, width, name = m2.groups()
            ports.append((dir_, width.strip(), name))
    return ports

def generate_inst(mod_name, ports, inst_name=None):
    if inst_name is None:
        inst_name = f'u_{mod_name}'
    lines = [f'    // {mod_name}']
    lines.append(f'    {mod_name} #(./*params*/) {inst_name} (')
    for i, (dir_, width, name) in enumerate(ports):
        comma = ',' if i < len(ports)-1 else ''
        # For instantiation, connect .port_name(port_name)
        lines.append(f'        .{name}({name}){comma}')
    lines.append(f'    );')
    return '\n'.join(lines)

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <module_name> <sv_file>")
        sys.exit(1)
    mod_name = sys.argv[1]
    sv_path = sys.argv[2]
    ports = extract_ports(sv_path)
    print(f"// Extracted {len(ports)} ports from {mod_name}")
    print(generate_inst(mod_name, ports))
