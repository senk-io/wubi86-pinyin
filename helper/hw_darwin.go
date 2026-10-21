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
