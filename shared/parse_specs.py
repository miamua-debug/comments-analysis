# shared/parse_specs.py — Unified product spec parser (JD + Tmall + Douyin)
#
# Three-phase extraction:
#   Phase 1: Structured attrs ('^' separated key:value, e.g. '系统:Windows 11^屏幕:双屏')
#   Phase 2: Color/spec string (e.g. '16GB / 512GB SSD / 深空灰' or '4G+64G / 白色')
#   Phase 3: Product name/title (regex fallback, lowest priority)
#
# Usage:
#   from shared.parse_specs import parse_specs
#   specs = parse_specs(product_title, variant_color, attrs_string)
#   # specs['RAM'], specs['Disk'], specs['CPU'], ... — empty string if not found

import re


def parse_specs(name, color, attrs):
    """Extract product specs from name/color/attrs (platform-agnostic)

    Args:
        name:  Product title (e.g. '戴尔灵越16Plus 16GB 512GB SSD 酷睿i7')
        color: SKU variant / spec string (e.g. '16GB / 512GB SSD / 深空灰')
        attrs: Structured attributes, '^' separated key:value pairs
               (e.g. '系统:Windows 11^屏幕数量:单屏^CPU型号:i7-13700H')
               or comma-separated tags as fallback (e.g. '品质好,性价比高')

    Returns:
        dict with keys: RAM, Disk, CPU, CPUModel, Model, ScreenCount, ScreenType,
                        System, SystemDetail, AccessoryType, ProductType, AI
    """
    specs = {
        'RAM': '', 'Disk': '', 'CPU': '', 'CPUModel': '', 'Model': '',
        'ScreenCount': '', 'ScreenType': '', 'System': '', 'SystemDetail': '',
        'AccessoryType': '', 'ProductType': '', 'AI': ''
    }

    # ===== Phase 1: Structured attrs ('^' separated key:value pairs) =====
    if attrs and ':' in attrs:
        parts = attrs.split('^')
        kv_parts = [p for p in parts if re.match(r'^[^:]+[:：].+', p)]
        if kv_parts:
            for part in kv_parts:
                # --- System / OS ---
                m = re.match(r'^(?:操作系统|系统|OS)[:：](.+)', part)
                if m:
                    sys_info = m.group(1).strip()
                    if re.search(r'Windows\s*(\d+)?', sys_info):
                        specs['System'] = 'Windows'
                        if v := re.search(r'(\d+)', sys_info):
                            specs['SystemDetail'] = f"Windows {v.group(1)}"
                    elif re.search(r'Android|安卓', sys_info):
                        specs['System'] = 'Android'
                        if v := re.search(r'(\d+(?:\.\d+)?)', sys_info):
                            specs['SystemDetail'] = f"Android {v.group(1)}"
                    elif re.search(r'macOS|Mac OS|OS X', sys_info):
                        specs['System'] = 'macOS'
                    elif re.search(r'iOS[^a-z]', sys_info):
                        specs['System'] = 'iOS'
                    elif re.search(r'Linux|Ubuntu|CentOS|Debian', sys_info):
                        specs['System'] = 'Linux'
                    elif re.search(r'HarmonyOS|鸿蒙', sys_info):
                        specs['System'] = 'HarmonyOS'
                    elif re.search(r'Chrome\s*OS', sys_info):
                        specs['System'] = 'ChromeOS'
                    else:
                        specs['System'] = sys_info
                    continue

                # --- Screen count ---
                m = re.match(r'^(?:屏幕数量|屏幕数)[:：](.+)', part)
                if m:
                    sc = m.group(1).strip()
                    if re.search(r'双屏|单屏|无屏|三屏', sc):
                        specs['ScreenCount'] = sc
                    elif sc.isdigit():
                        specs['ScreenCount'] = f"{sc}屏"
                    continue

                # --- Screen type ---
                m = re.match(r'^(?:屏幕类型|屏幕)[:：](.+)', part)
                if m:
                    st = m.group(1).strip()
                    if re.search(r'电容|液晶|触摸|触控|高清|LED|LCD|IPS|OLED', st):
                        specs['ScreenType'] = st
                    continue

                # --- CPU ---
                m = re.match(r'^(?:CPU型号|CPU|处理器|处理器型号|核心)[:：](.+)', part)
                if m:
                    cpu_info = m.group(1).strip()
                    if re.search(r'酷睿\s*(i\d)', cpu_info):
                        specs['CPU'] = 'Intel'
                        m_core = re.search(r'酷睿\s*(i\d)', cpu_info)
                        specs['CPUModel'] = f"酷睿{m_core.group(1)}" if m_core else '酷睿'
                    elif re.search(r'\bIntel\b', cpu_info):
                        specs['CPU'] = 'Intel'; specs['CPUModel'] = cpu_info
                    elif re.search(r'锐龙|Ryzen\s*(R\d|\d)', cpu_info, re.IGNORECASE):
                        specs['CPU'] = 'AMD'
                        if rm := re.search(r'(?:锐龙|Ryzen)\s*(R?\d\s*\d*)', cpu_info, re.IGNORECASE):
                            specs['CPUModel'] = rm.group(0)
                        else:
                            specs['CPUModel'] = cpu_info
                    elif re.search(r'骁龙|Snapdragon', cpu_info, re.IGNORECASE):
                        specs['CPU'] = 'Qualcomm'; specs['CPUModel'] = cpu_info
                    elif re.search(r'麒麟|Kirin', cpu_info, re.IGNORECASE):
                        specs['CPU'] = '海思麒麟'; specs['CPUModel'] = cpu_info
                    elif re.search(r'\bM\d+\b', cpu_info):
                        specs['CPU'] = 'Apple Silicon'; specs['CPUModel'] = cpu_info
                    elif re.search(r'四核', cpu_info):
                        specs['CPU'] = '四核'
                    elif re.search(r'八核', cpu_info):
                        specs['CPU'] = '八核'
                    elif re.search(r'十核|十二核', cpu_info):
                        specs['CPU'] = cpu_info
                    elif re.search(r'疾速', cpu_info):
                        specs['CPU'] = '疾速处理器'
                    else:
                        specs['CPU'] = cpu_info
                    continue

                # --- RAM ---
                m = re.match(r'^(?:内存|RAM|运存|内存容量|运行内存|机身内存)[:：](.+)', part)
                if m:
                    ram_info = m.group(1).strip()
                    if rm := re.search(r'(\d+)\s*G', ram_info):
                        specs['RAM'] = f"{rm.group(1)}G"
                    continue

                # --- Disk / Storage ---
                m = re.match(r'^(?:硬盘类型|硬盘容量|硬盘|存储容量|存储|SSD|固态硬盘|固态|机械硬盘)[:：](.+)', part)
                if m:
                    disk_info = m.group(1).strip()
                    if dm := re.search(r'(\d+)\s*G', disk_info):
                        specs['Disk'] = f"{dm.group(1)}G"
                    elif re.search(r'SSD|固态', disk_info):
                        specs['Disk'] = disk_info
                    elif re.search(r'机械|HDD', disk_info):
                        specs['Disk'] = disk_info
                    elif disk_info:
                        specs['Disk'] = disk_info
                    continue

                # --- Model ---
                m = re.match(r'^(?:型号|系列|款式)[:：](.+)', part)
                if m:
                    model_info = m.group(1).strip()
                    if not specs['Model'] or len(model_info) > len(specs['Model']):
                        specs['Model'] = model_info
                    continue

                # --- AI ---
                m = re.match(r'^(?:AI|人工智能|智能识别)[:：](.+)', part)
                if m:
                    ai_info = m.group(1).strip()
                    if ai_info not in ('否', '无', '不支持'):
                        specs['AI'] = '是'
                    continue

    # ===== Phase 2: Color / spec string =====
    if color:
        if not specs['Model'] and (m := re.search(r'([A-Z]\d+)', color)):
            specs['Model'] = m.group(1)
        # JD-style: RAM+Disk '+' connected (e.g. '4G+64G')
        if not specs['RAM'] and (m := re.search(r'(\d+)G?\s*\+\s*(\d+)G', color)):
            specs['RAM'] = f"{m.group(1)}G"
            specs['Disk'] = f"{m.group(2)}G"
        # Tmall-style: '/' separated segments, try each for RAM/Disk
        if not specs['RAM'] or not specs['Disk']:
            for seg in color.split('/'):
                seg = seg.strip()
                if not specs['RAM'] and re.search(r'(?:内存|运存|RAM)', seg):
                    if rm := re.search(r'(\d+)\s*G', seg):
                        specs['RAM'] = f"{rm.group(1)}G"
                if not specs['Disk'] and re.search(r'(?:硬盘|存储|SSD|固态|机械|HDD)', seg):
                    if dm := re.search(r'(\d+)\s*G', seg):
                        specs['Disk'] = f"{dm.group(1)}G"
            # Fallback: first G-value → RAM, second → Disk
            g_vals = re.findall(r'(\d+)\s*G', color)
            if not specs['RAM'] and len(g_vals) >= 1:
                specs['RAM'] = f"{g_vals[0]}G"
            if not specs['Disk'] and len(g_vals) >= 2:
                specs['Disk'] = f"{g_vals[1]}G"
        if not specs['ScreenCount'] and re.search(r'双屏|单屏|无屏', color):
            specs['ScreenCount'] = re.search(r'双屏|单屏|无屏', color).group(0)
        if re.search(r'酷睿\s*(i\d)', color):
            specs['CPU'] = 'Intel'
            _m = re.search(r'酷睿\s*(i\d)', color)
            specs['CPUModel'] = f"酷睿{_m.group(1)}" if _m else '酷睿'
        elif re.search(r'锐龙|Ryzen', color, re.IGNORECASE):
            specs['CPU'] = 'AMD'
            if rm := re.search(r'(?:锐龙|Ryzen)\s*(R?\d\s*\d*)', color, re.IGNORECASE):
                specs['CPUModel'] = rm.group(0)
        if re.search(r'AI识别|Ai识别|智能识物|商品识别|自动识物', color):
            specs['AI'] = '是'
        if re.search(r'Windows', color):
            specs['System'] = 'Windows'
        elif re.search(r'Android|安卓', color):
            specs['System'] = 'Android'

    # ===== Phase 3: Name / title (lowest priority) =====
    if name:
        # JD-style: RAM+Disk '+' connected
        if not specs['RAM'] and (m := re.search(r'(\d+)G?\s*\+\s*(\d+)G', name)):
            specs['RAM'] = f"{m.group(1)}G"
            specs['Disk'] = f"{m.group(2)}G"
        elif not specs['RAM'] and re.search(r'(\d+)G\s*(?:内存|运存|RAM)', name):
            specs['RAM'] = f"{re.search(r'(\d+)G\s*(?:内存|运存|RAM)', name).group(1)}G"
        # Tmall-style: '/' separated segments
        if not specs['RAM'] or not specs['Disk']:
            for seg in name.split('/'):
                seg = seg.strip()
                if not specs['RAM'] and re.search(r'(?:内存|运存|RAM)', seg):
                    if rm := re.search(r'(\d+)\s*[GT]', seg):
                        specs['RAM'] = f"{rm.group(1)}{rm.group(0)[-1]}"
                if not specs['Disk'] and re.search(r'(?:硬盘|存储|SSD|固态|机械|HDD)', seg):
                    if dm := re.search(r'(\d+)\s*[GT]', seg):
                        specs['Disk'] = f"{dm.group(1)}{dm.group(0)[-1]}"
            g_vals = re.findall(r'(\d+)\s*G', name)
            t_vals = re.findall(r'(\d+)\s*T', name)
            if not specs['RAM'] and len(g_vals) >= 1:
                specs['RAM'] = f"{g_vals[0]}G"
            if not specs['Disk'] and len(g_vals) >= 2:
                specs['Disk'] = f"{g_vals[1]}G"
            if not specs['Disk'] and len(t_vals) >= 1:
                specs['Disk'] = f"{t_vals[0]}T"
        # TB support
        if not specs['Disk'] and re.search(r'(\d+)\s*T\s*(?:硬盘|存储|固态|SSD|闪存|大存储|机械|HDD)', name):
            specs['Disk'] = f"{re.search(r'(\d+)\s*T\s*(?:硬盘|存储|固态|SSD|闪存|大存储|机械|HDD)', name).group(1)}T"
        # CPU from name
        if (not specs['CPU']) and re.search(r'酷睿\s*(i\d)', name):
            specs['CPU'] = 'Intel'
            specs['CPUModel'] = f"酷睿{re.search(r'酷睿\s*(i\d)', name).group(1)}"
        elif not specs['CPU'] and re.search(r'\bIntel\b', name):
            specs['CPU'] = 'Intel'
        elif not specs['CPU'] and re.search(r'锐龙|Ryzen', name, re.IGNORECASE):
            specs['CPU'] = 'AMD'
            if rm := re.search(r'(?:锐龙|Ryzen)\s*(R?\d\s*\d*)', name, re.IGNORECASE):
                specs['CPUModel'] = rm.group(0)
        elif not specs['CPU'] and re.search(r'骁龙|Snapdragon', name, re.IGNORECASE):
            specs['CPU'] = 'Qualcomm'
            specs['CPUModel'] = name[name.find('骁龙'):][:20] if '骁龙' in name else ''
        elif not specs['CPU'] and re.search(r'四核', name):
            specs['CPU'] = '四核'
        elif not specs['CPU'] and re.search(r'八核', name):
            specs['CPU'] = '八核'
        elif not specs['CPU'] and re.search(r'疾速', name):
            specs['CPU'] = '疾速处理器'
        # Model from name
        if not specs['Model']:
            if m := re.search(r'(?:型号|系列|款|机型)\s*[:：]?\s*([A-Z]\d+)', name):
                specs['Model'] = m.group(1)
            else:
                # Use lookbehind/lookahead instead of \b (Python's \b treats Chinese as \w)
                candidates = re.findall(r'(?<![A-Za-z])([A-Z]\d+)(?![A-Za-z])', name)
                if candidates:
                    skip_prefixes = ['USB', 'Type', 'HDMI', 'VGA', 'RJ', 'DC', 'PD']
                    valid = [c for c in candidates if not any(
                        name[max(0, name.index(c)-len(p)):name.index(c)].upper() == p.upper()
                        for p in skip_prefixes)]
                    if valid:
                        specs['Model'] = valid[-1]
        # Screen
        if not specs['ScreenCount'] and re.search(r'双屏|单屏|无屏', name):
            specs['ScreenCount'] = re.search(r'双屏|单屏|无屏', name).group(0)
        if not specs['ScreenType'] and re.search(r'电容屏|液晶|触摸屏|触屏|触控屏|高清屏|LED|LCD', name):
            specs['ScreenType'] = re.search(r'电容屏|液晶|触摸屏|触屏|触控屏|高清屏|LED|LCD', name).group(0)
        # System
        if not specs['System']:
            if re.search(r'Windows\s*(\d+)?', name):
                specs['System'] = 'Windows'
            elif re.search(r'Android|安卓', name):
                specs['System'] = 'Android'
        # AI
        if not specs['AI'] and re.search(r'AI识别|Ai识别|AI识物|智能识物|商品识别|自动识物|自动识别商品', name):
            specs['AI'] = '是'
        # Product type
        if not specs['ProductType']:
            if re.search(r'收银秤|称重收银|称重一体|收银称|电子称|条码秤|标签秤|智能称|称重秤', name):
                specs['ProductType'] = '收银秤'
            elif re.search(r'收银机|收银系统|收款机|POS机|收银终端|收银一体|一体收银|零售收银', name):
                specs['ProductType'] = '收银机'
        # Accessory type
        if not specs['AccessoryType']:
            if re.search(r'打印纸|标签纸|小票纸|收银纸|热敏纸|价签纸|碳带|色带|墨水', name):
                specs['AccessoryType'] = '耗材'
            elif re.search(r'扫码枪|扫码平台|扫描枪|条码枪|扫描平台', name):
                specs['AccessoryType'] = '扫码设备'
            elif re.search(r'标签机|打印机|小票机|票据打印机|热敏打印机|标签打印机|厨房打印机', name):
                specs['AccessoryType'] = '打印设备'
            elif re.search(r'钱箱|收银箱|现金箱', name):
                specs['AccessoryType'] = '钱箱'
            elif re.search(r'支架|壁挂|挂架|底座|立柱', name):
                specs['AccessoryType'] = '安装配件'
            elif re.search(r'存储卡|内存卡|TF卡|SD卡', name):
                specs['AccessoryType'] = '存储卡'
        if specs['AccessoryType']:
            specs['ProductType'] = f"配件/{specs['AccessoryType']}"

    return specs
