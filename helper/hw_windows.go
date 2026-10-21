package main

import (
	"syscall"
	"unsafe"
)

var (
	kernel32                 = syscall.NewLazyDLL("kernel32.dll")
	procGlobalMemoryStatusEx = kernel32.NewProc("GlobalMemoryStatusEx")
	procGetSystemPowerStatus = kernel32.NewProc("GetSystemPowerStatus")
)

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

func memoryStatus() (memoryStatusEx, bool) {
	var mem memoryStatusEx
	mem.Length = uint32(unsafe.Sizeof(mem))
	r, _, _ := procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&mem)))
	return mem, r != 0
}

func probeHW() hwInfo {
	var hw hwInfo
	if mem, ok := memoryStatus(); ok {
		hw.memBytes = mem.TotalPhys
	}
	var power struct {
		ACLineStatus        byte
		BatteryFlag         byte
		BatteryLifePercent  byte
		SystemStatusFlag    byte
		BatteryLifeTime     uint32
		BatteryFullLifeTime uint32
	}
	if r, _, _ := procGetSystemPowerStatus.Call(uintptr(unsafe.Pointer(&power))); r != 0 {
		hw.onBattery = power.ACLineStatus == 0 // 0 为电池供电，1 为外接电源，255 为未知
	}
	return hw
}

// 物理内存占用达到 85% 视为紧张
func probeMemoryTight() bool {
	mem, ok := memoryStatus()
	return ok && mem.MemoryLoad >= 85
}
