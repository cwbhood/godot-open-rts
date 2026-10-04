extends Node

# Turns crash reports left by QA runs that died into report files and lists every pending
# report. Run it after a batch of QA matches:
#
#   godot --headless --path . res://tools/crash/Collect.tscn
#
# A crashed run's report is also copied to that run's --out folder as crash_report.txt.

const ReportText = preload("res://source/crash/ReportText.gd")


func _ready():
	var reports = CrashReporter.pending_reports()
	print(
		(
			"%d crash report(s) in %s"
			% [reports.size(), ProjectSettings.globalize_path(CrashReporter.DIR)]
		)
	)
	for report in reports:
		print("  %s  %s" % [report["path"].get_file(), ReportText.title(report)])
	get_tree().quit()
