"""HWiNFO sensor names for each sensor key the designs use (data-sensor="CPUTEMP", ...). build_skin.py looks
them up in HWiNFO's gadget registry export (HKCU\\Software\\HWiNFO64\\VSB). If a value shows "--", add the
name HWiNFO uses for it on your PC to its list."""

# L-Connect key -> HWiNFO gadget labels to look for (first match wins, case-insensitive).
LABELS = {
    "CPULOAD":    ["Total CPU Usage"],
    "CPUTEMP":    ["CPU (Tctl/Tdie)", "CPU Package", "CPU (Tdie)", "CPU Temperature"],
    "CPUPWR":     ["CPU Package Power", "CPU Power"],
    "CPUCLOCK":   ["Core Clocks (avg)", "Average Effective Clock", "Core 0 Clock"],
    "CPUFAN":     ["CPU", "CPU Fan"],
    "GPUTEMP":    ["GPU Temperature"],
    "GPUHOTSPOT": ["GPU Hot Spot Temperature"],
    "GPUMEMTEMP": ["GPU Memory Junction Temperature"],
    "GPULOAD":    ["GPU Core Load", "GPU Utilization"],
    "GPUPWR":     ["GPU Power"],
    "GPUCLOCK":   ["GPU Effective Clock", "GPU Clock"],
    "GPUFAN":     ["GPU Fan1", "GPU Fan"],
    "GPUFAN2":    ["GPU Fan2"],
    "GPURAMLOAD": ["GPU Memory Usage"],
    "GPURAM":     ["GPU Memory Allocated", "GPU D3D Memory Dedicated"],
    "RAMLOAD":    ["Physical Memory Load"],
    "DOWNSPEED":  ["Current DL rate"],
    "UPSPEED":    ["Current UP rate"],
    "FPS":        ["Framerate Displayed (avg)", "Framerate (avg)", "Framerate"],
}
