-- Path of Building
--
-- Module: Calc Sensitivity
-- Prototype: measures which stat axes a build actually scales with, by injecting
-- marginal amounts of each stat and observing the resulting change in a target metric.
--
-- This is a console-only prototype driven by F7 in dev mode; it has no UI yet.
--

local calcs = ...
local ipairs = ipairs
local t_insert = table.insert
local t_sort = table.sort
local s_format = string.format
local m_abs = math.abs

-- Sample points, as multiples of the nominal step for each axis. Sweeping instead of
-- taking a single sample is what exposes non-linearity: a build with compounding
-- synergies (attribute stackers, conversion chains) returns more per unit as the
-- investment grows, which a single derivative at the margin would hide.
local sweepPoints = { 0.25, 0.5, 1, 2, 4 }

-- Pool axes are stats the build holds a quantity of, so a percentage change is
-- meaningful and elasticity is comparable across all of them.
local poolAxes = {
	{ label = "Strength", stat = "Str", mod = "Str" },
	{ label = "Dexterity", stat = "Dex", mod = "Dex" },
	{ label = "Intelligence", stat = "Int", mod = "Int" },
	{ label = "Life", stat = "Life", mod = "Life" },
	{ label = "Energy Shield", stat = "EnergyShield", mod = "EnergyShield" },
	{ label = "Mana", stat = "Mana", mod = "Mana" },
	{ label = "Accuracy", stat = "Accuracy", mod = "Accuracy" },
	{ label = "Armour", stat = "Armour", mod = "Armour" },
	{ label = "Evasion", stat = "Evasion", mod = "Evasion" },
}

-- Multiplier axes have no pool to normalise against, so they are reported as the
-- gain from one typical affix worth of investment instead.
local multiplierAxes = {
	{ label = "Increased Attack Speed", mod = "Speed", modType = "INC", step = 10, flags = ModFlag.Attack, unit = "%" },
	{ label = "Increased Cast Speed", mod = "Speed", modType = "INC", step = 10, flags = ModFlag.Cast, unit = "%" },
	{ label = "Increased Crit Chance", mod = "CritChance", modType = "INC", step = 20, unit = "%" },
	{ label = "Crit Multiplier", mod = "CritMultiplier", modType = "BASE", step = 15, unit = "%" },
	{ label = "Increased Damage", mod = "Damage", modType = "INC", step = 20, unit = "%" },
	{ label = "More Damage", mod = "Damage", modType = "MORE", step = 10, unit = "%" },
	{ label = "Increased Elemental Damage", mod = "ElementalDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Physical Damage", mod = "PhysicalDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Lightning Damage", mod = "LightningDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Fire Damage", mod = "FireDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Cold Damage", mod = "ColdDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Chaos Damage", mod = "ChaosDamage", modType = "INC", step = 20, unit = "%" },
	{ label = "Increased Life", mod = "Life", modType = "INC", step = 10, unit = "%" },
	{ label = "Increased Energy Shield", mod = "EnergyShield", modType = "INC", step = 10, unit = "%" },
}

---Classifies how the return on an axis changes as investment grows.
---Compares the marginal yield of the smallest sample against the largest.
local function classifyCurve(samples)
	local first, last = samples[1], samples[#samples]
	if not first or not last then
		return "?"
	end
	if first.perUnit == 0 then
		-- Nothing at the smallest step but something later means the axis pays out in
		-- steps rather than continuously, which usually indicates integer division
		-- somewhere ("per N maximum Life"). A marginal derivative is the wrong tool
		-- for these: the reported gain depends entirely on where the sample lands
		-- relative to the next threshold.
		return last.perUnit ~= 0 and "ESCADA (ver sweep)" or "sem efeito"
	end
	local ratio = last.perUnit / first.perUnit
	if ratio > 1.05 then
		return s_format("acelera (x%.2f)", ratio)
	elseif ratio < 0.95 then
		return s_format("achata  (x%.2f)", ratio)
	end
	return "linear"
end

---Runs one axis through the full sweep.
---@param calcFunc function @Calculator from calcs.getMiscCalculator
---@param baseValue number @Target metric before any injection
---@param nominalStep number @Amount injected at sweep point 1.0
---@param modFactory function @Given an amount, returns the list of mods to inject
---@param statName string @Output field holding the target metric
local function sweepAxis(calcFunc, baseValue, nominalStep, modFactory, statName)
	local samples = { }
	for _, point in ipairs(sweepPoints) do
		local amount = nominalStep * point
		local output = calcFunc({ extraMods = modFactory(amount) })
		local newValue = output[statName] or 0
		local delta = newValue - baseValue
		t_insert(samples, {
			point = point,
			amount = amount,
			delta = delta,
			-- Marginal yield per unit injected, which is what makes sample points
			-- of different sizes comparable to each other.
			perUnit = amount ~= 0 and (delta / amount) or 0,
		})
	end
	return samples
end

---Measures every axis against a target metric and reports a ranked breakdown.
---Output goes to both the console and a text file, since the console toggle is
---unreliable on non-US keyboard layouts.
---@param build table
---@param statName string|nil @Output field to optimise for; defaults to Hit DPS
function calcs.runSensitivity(build, statName)
	statName = statName or "TotalDPS"

	local lines = { }
	local function out(fmt, ...)
		local line = select("#", ...) > 0 and s_format(fmt, ...) or fmt
		t_insert(lines, line)
		ConPrintf("%s", line)
	end

	local function writeReport()
		local path = (main and main.userPath or "") .. "sensitivity_report.txt"
		local file = io.open(path, "w")
		if not file then
			ConPrintf("Sensitivity: could not write report to %s", path)
			return
		end
		file:write(table.concat(lines, "\n"), "\n")
		file:close()
		ConPrintf("Sensitivity: report written to %s", path)
	end

	local calcFunc, baseOutput = calcs.getMiscCalculator(build)
	local baseValue = baseOutput[statName] or 0

	out("=== ANALISE DE SENSIBILIDADE =============================")
	out("Metrica alvo : %s", statName)
	out("Valor base   : %.1f", baseValue)

	if baseValue == 0 then
		out("ERRO: metrica base vale zero, nada a comparar.")
		writeReport()
		return
	end

	-- Control pass: injecting nothing must reproduce the base value. If it does not,
	-- the calculator is not rebuilding the character faithfully (some setup that only
	-- happens on the initial pass has been lost), and every number below would be
	-- measuring that discrepancy rather than the axis under test.
	local controlValue = calcFunc({ extraMods = { } })[statName] or 0
	local drift = m_abs(controlValue - baseValue) / baseValue
	if drift > 0.001 then
		out("")
		out("AVISO: passe de controle divergiu da base em %.2f%% (%.1f vs %.1f).", drift * 100, controlValue, baseValue)
		out("Os numeros abaixo NAO sao confiaveis - o calculador nao esta reproduzindo a build.")
	end

	local poolResults, multResults, inertAxes = { }, { }, { }

	-- Pool axes: step is 1% of what the build already has, so the reported
	-- elasticity reads directly as "% metric gained per 1% more of this stat".
	for _, axis in ipairs(poolAxes) do
		local current = baseOutput[axis.stat] or 0
		if current > 0 then
			local step = current * 0.01
			local samples = sweepAxis(calcFunc, baseValue, step, function(amount)
				return { modLib.createMod(axis.mod, "BASE", amount, "Sensitivity") }
			end, statName)
			local nominal = samples[3]
			local elasticity = (nominal.delta / baseValue) / 0.01
			local entry = {
				label = axis.label,
				current = current,
				step = step,
				delta = nominal.delta,
				elasticity = elasticity,
				curve = classifyCurve(samples),
				samples = samples,
			}
			if m_abs(elasticity) < 0.0001 then
				t_insert(inertAxes, axis.label)
			else
				t_insert(poolResults, entry)
			end
		end
	end

	-- Multiplier axes: no pool to normalise against, so these are reported as the
	-- absolute gain from one affix-sized chunk of investment.
	for _, axis in ipairs(multiplierAxes) do
		local samples = sweepAxis(calcFunc, baseValue, axis.step, function(amount)
			return { modLib.createMod(axis.mod, axis.modType, amount, "Sensitivity", axis.flags) }
		end, statName)
		local nominal = samples[3]
		local entry = {
			label = axis.label,
			step = axis.step,
			unit = axis.unit,
			delta = nominal.delta,
			pct = nominal.delta / baseValue * 100,
			curve = classifyCurve(samples),
			samples = samples,
		}
		if m_abs(entry.pct) < 0.0001 then
			t_insert(inertAxes, axis.label)
		else
			t_insert(multResults, entry)
		end
	end

	t_sort(poolResults, function(a, b) return a.elasticity > b.elasticity end)
	t_sort(multResults, function(a, b) return a.pct > b.pct end)

	out("")
	out("--- EIXOS DE POOL (elasticidade: %% metrica por +1%% do stat) ---")
	out("%-16s %10s %9s %14s %8s  %s", "Eixo", "Atual", "+1%", "Ganho", "Elast.", "Curva")
	for _, r in ipairs(poolResults) do
		out("%-16s %10.0f %9.1f %14.1f %8.3f  %s", r.label, r.current, r.step, r.delta, r.elasticity, r.curve)
	end

	out("")
	out("--- EIXOS MULTIPLICADORES (ganho por afixo tipico) ---")
	out("%-28s %8s %14s %8s  %s", "Eixo", "Passo", "Ganho", "%", "Curva")
	for _, r in ipairs(multResults) do
		out("%-28s %7d%s %14.1f %7.2f%%  %s", r.label, r.step, r.unit, r.delta, r.pct, r.curve)
	end

	-- Raw sample points behind every classification. The summary tables report a single
	-- derivative, which is only trustworthy when the axis pays out continuously; this
	-- section is what lets a stepped or non-linear axis be recognised as such instead of
	-- being read as a smooth number.
	out("")
	out("--- DETALHE DO SWEEP (ganho absoluto em cada ponto de amostragem) ---")
	out("%-28s %12s %12s %12s %12s %12s", "Eixo", "x0.25", "x0.5", "x1", "x2", "x4")
	local function dumpSamples(results)
		for _, r in ipairs(results) do
			local cells = { }
			for _, s in ipairs(r.samples) do
				t_insert(cells, s_format("%12.0f", s.delta))
			end
			out("%-28s %s", r.label, table.concat(cells, " "))
		end
	end
	dumpSamples(poolResults)
	dumpSamples(multResults)

	-- Surfaced explicitly rather than dropped: an axis reading zero may genuinely not
	-- apply to this build, but it can equally mean the injection never landed. Silently
	-- omitting them would make a broken axis look like an irrelevant one.
	if #inertAxes > 0 then
		out("")
		out("--- SEM EFEITO MENSURAVEL (verificar se se aplica a esta build) ---")
		for _, label in ipairs(inertAxes) do
			out("  %s", label)
		end
	end

	out("")
	out("=== FIM ==================================================")
	writeReport()
end
