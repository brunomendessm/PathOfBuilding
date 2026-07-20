-- Path of Building
--
-- Class: Analytics Tab
-- Analyses that are too expensive to keep live, run on demand and shown in collapsible
-- sections in the style of the Calcs tab.
--
local ipairs = ipairs
local t_insert = table.insert
local s_format = string.format
local m_floor = math.floor

local AnalyticsTabClass = newClass("AnalyticsTab", "ControlHost", "Control", function(self, build)
	self.ControlHost()
	self.Control()

	self.build = build
	self.calcs = LoadModule("Modules/Calcs")

	self.report = nil
	self.progress = nil
	self.builder = nil
	-- Results are positional: they describe the build at the point it was measured, and on
	-- a build that scales in steps a small edit moves every number. Staleness is tracked
	-- against the revision the calculations were rebuilt at, rather than a flag someone
	-- has to remember to set, so no edit can quietly leave stale numbers looking current.
	self.reportRevision = nil
	self.statName = "TotalDPS"
	self.statLabel = "Hit DPS"

	self.sections = {
		{ id = "invest", label = "Where to invest", collapsed = false, height = 220 },
		{ id = "breakpoints", label = "Breakpoints", collapsed = false, height = 180 },
	}

	local metricList = { }
	for _, entry in ipairs(data.powerStatList) do
		if entry.stat and not entry.ignoreForNodes then
			t_insert(metricList, entry)
		end
	end

	self.controls.metricLabel = new("LabelControl", { "TOPLEFT", self, "TOPLEFT" }, { 8, 12, 0, 16 }, "^7Metric:")
	self.controls.metricSelect = new("DropDownControl", { "LEFT", self.controls.metricLabel, "RIGHT" }, { 8, 0, 200, 20 }, metricList, function(index, value)
		self.statName = value.stat
		self.statLabel = value.label
		-- Changing the metric invalidates outright rather than marking stale: the previous
		-- numbers answer a different question, so keeping them on screen would be wrong
		-- in a way a warning label does not cover.
		self.report = nil
		self.controls.investList:SetReport(nil)
		self.controls.breakpointList:SetReport(nil)
	end)

	self.controls.analyse = new("ButtonControl", { "LEFT", self.controls.metricSelect, "RIGHT" }, { 8, 0, 110, 20 }, function()
		return self.builder and "Cancel" or "Analyse"
	end, function()
		if self.builder then
			self.builder = nil
			self.progress = nil
		else
			self:StartAnalysis()
		end
	end)

	self.controls.status = new("LabelControl", { "LEFT", self.controls.analyse, "RIGHT" }, { 10, 0, 0, 16 }, function()
		if self.builder then
			return s_format("^7Analysing... %d%%", self.progress or 0)
		elseif not self.report then
			return "^8Not analysed yet"
		elseif self.report.error then
			return colorCodes.NEGATIVE .. self.report.error
		elseif self:IsStale() then
			return colorCodes.WARNING .. "Build changed since last run - results are stale"
		end
		return s_format("^7%s: ^7%s", self.statLabel, formatNumSep(s_format("%.0f", self.report.baseValue)))
	end)

	-- A control pass that fails to reproduce the base value means the calculator is not
	-- rebuilding the character faithfully. Surfaced loudly, because that failure produces
	-- plausible-looking numbers rather than an error.
	self.controls.controlWarning = new("LabelControl", { "TOPLEFT", self.controls.metricLabel, "BOTTOMLEFT" }, { 0, 6, 0, 16 }, function()
		return colorCodes.NEGATIVE .. s_format("Control pass diverged from base by %.2f%% - these numbers are not trustworthy",
			(self.report and self.report.controlDrift or 0) * 100)
	end)
	self.controls.controlWarning.shown = function()
		return self.report and not self.report.error and self.report.controlDrift and self.report.controlDrift > 0.001
	end

	for index, section in ipairs(self.sections) do
		self.controls["section" .. section.id] = new("SectionControl", { "TOPLEFT", self, "TOPLEFT" }, { 0, 0, 0, 0 }, section.label)
		self.controls["toggle" .. section.id] = new("ButtonControl", { "TOPRIGHT", self.controls["section" .. section.id], "TOPRIGHT" }, { -4, 3, 16, 16 }, function()
			return section.collapsed and "+" or "-"
		end, function()
			section.collapsed = not section.collapsed
		end)
	end

	-- Offset leaves room for the list's own label, which draws above its top-left corner
	-- and would otherwise sit on top of the section title.
	self.controls.investList = new("SensitivityListControl", { "TOPLEFT", self.controls.sectioninvest, "TOPLEFT" }, { 6, 34, 100, 100 })
	self.controls.investList.shown = function()
		return not self.sections[1].collapsed
	end

	self.controls.breakpointList = new("BreakpointListControl", { "TOPLEFT", self.controls.sectionbreakpoints, "TOPLEFT" }, { 6, 34, 100, 100 })
	self.controls.breakpointList.shown = function()
		return not self.sections[2].collapsed
	end
end)

---True when the calculations have been rebuilt since the report was measured, which makes
---every number in it describe a build that no longer exists.
function AnalyticsTabClass:IsStale()
	return self.report ~= nil and self.reportRevision ~= self.build.outputRevision
end

function AnalyticsTabClass:StartAnalysis()
	self.progress = 0
	local statName = self.statName
	self.builder = coroutine.create(function()
		return self.calcs.buildSensitivityReport(self.build, statName, function(percent)
			self.progress = percent
		end)
	end)
end

---Advances the analysis coroutine by one slice. Driven from Draw so the tab keeps
---responding while a few hundred calculation passes run.
function AnalyticsTabClass:StepAnalysis()
	if not self.builder then
		return
	end
	local ok, result = coroutine.resume(self.builder)
	if not ok then
		self.builder = nil
		self.progress = nil
		if launch.devMode then
			error(result)
		end
		return
	end
	if coroutine.status(self.builder) == "dead" then
		self.builder = nil
		self.progress = nil
		self.report = result
		self.reportRevision = self.build.outputRevision
		self.controls.investList:SetReport(result)
		self.controls.breakpointList:SetReport(result)
	end
end

function AnalyticsTabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height

	self:StepAnalysis()

	-- Sections are stacked top to bottom, each taking its own height only while expanded,
	-- so collapsing one pulls everything below it up.
	local sectionWidth = viewPort.width - 16
	local yPos = self.controls.controlWarning:IsShown() and 62 or 42
	for index, section in ipairs(self.sections) do
		local control = self.controls["section" .. section.id]
		local height = section.collapsed and 22 or section.height
		control.x = 8
		control.y = yPos
		control.width = sectionWidth
		control.height = height
		yPos = yPos + height + 12
	end

	-- Height budget: 34 for the list's offset inside the section, 8 for breathing room at
	-- the bottom, so the list never draws past the section border.
	local listWidth = sectionWidth - 12
	self.controls.investList.width = listWidth
	self.controls.investList.height = self.sections[1].height - 42
	self.controls.investList:UpdateColumns(listWidth)
	self.controls.breakpointList.width = listWidth
	self.controls.breakpointList.height = self.sections[2].height - 42
	self.controls.breakpointList:UpdateColumns(listWidth)

	self:ProcessControlsInput(inputEvents, viewPort)

	main:DrawBackground(viewPort)
	self:DrawControls(viewPort)
end
