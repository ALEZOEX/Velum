//go:build !linux

package main

func checkTUNResources(_ map[string]any) error { return nil }
