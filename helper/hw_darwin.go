package main

import (
	"os/exec"
	"strconv"
	"strings"
)

func probeHW() hwInfo {
	var hw hwInfo
	if out, err := exec.Command("/usr/sbin/sysctl", "-n", "hw.memsize").Output(); err == nil {
		hw.memBytes, _ = strconv.ParseUint(strings.TrimSpace(string(out)), 10, 64)
	}
	// 第一行形如 "Now drawing from 'Battery Power'" 或 "'AC Power'"
	if out, err := exec.Command("/usr/bin/pmset", "-g", "batt").Output(); err == nil {
		hw.onBattery = strings.Contains(strings.SplitN(string(out), "\n", 2)[0], "Battery Power")
	}
	return hw
}

// 内核的内存压力等级：1 正常，2 警告，4 严重（活动监视器里的"内存压力"变黄、变红）。
// 不看 swap 用量：swap 只会慢慢回落，压力早已解除后仍可能很高。
func probeMemoryTight() bool {
	out, err := exec.Command("/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level").Output()
	if err != nil {
		return false
	}
	level, err := strconv.Atoi(strings.TrimSpace(string(out)))
	return err == nil && level >= 2
}
