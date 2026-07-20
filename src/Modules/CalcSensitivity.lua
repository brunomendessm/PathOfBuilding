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
local pairs = pairs
local type = type
local t_insert = table.insert
local t_sort = table.sort
local s_format = string.format
local m_abs = math.abs
local m_floor = math.floor
local m_min = math.min
local m_max = math.max

-- Sample points, as multiples of the nominal step for each axis. Sweeping instead of
-- taking a single sample is what exposes non-linearity: a build with compounding
-- synergies (attribute stackers, conversion chains) returns more per unit as the
-- investment grows, which a single derivative at the margin would hide.
local sweepPoints = { 0.25, 0.5, 1, 2, 4 }

-- Pool axes are stats the build holds a quantity of, so a percentage change is
-- meaningful and elasticity is comparable across all of them.
-- affixPattern matches the flat affix that grants the stat, with a single capture for
-- the top of the roll, so the per-affix column can be sourced from the real mod pool.
local poolAxes = {
	{ label = "Strength", stat = "Str", mod = "Str", affixPattern = "^%+%(%d+%-(%d+)%) to Strength$" },
	{ label = "Dexterity", stat = "Dex", mod = "Dex", affixPattern = "^%+%(%d+%-(%d+)%) to Dexterity$" },
	{ label = "Intelligence", stat = "Int", mod = "Int", affixPattern = "^%+%(%d+%-(%d+)%) to Intelligence$" },
	{ label = "Life", stat = "Life", mod = "Life", affixPattern = "^%+%(%d+%-(%d+)%) to maximum Life$" },
	{ label = "Energy Shield", stat = "EnergyShield", mod = "EnergyShield", affixPattern = "^%+%(%d+%-(%d+)%) to maximum Energy Shield$" },
	{ label = "Mana", stat = "Mana", mod = "Mana", affixPattern = "^%+%(%d+%-(%d+)%) to maximum Mana$" },
	{ label = "Accuracy", stat = "Accuracy", mod = "Accuracy", affixPattern = "^%+%(%d+%-(%d+)%) to Accuracy Rating$" },
	{ label = "Armour", stat = "Armour", mod = "Armour", affixPattern = "^%+%(%d+%-(%d+)%) to Armour$" },
	{ label = "Evasion", stat = "Evasion", mod = "Evasion", affixPattern = "^%+%(%d+%-(%d+)%) to Evasion Rating$" },
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

---Finds the largest roll of a flat affix matching the given pattern in the explicit mod
---pool. This keeps the per-affix column tied to what the game can actually roll, rather
---than to an assumed affix size that would quietly decide the ranking.
---Only mods with a non-zero spawn weight somewhere are considered, to skip mods that
---exist in the data but cannot appear on an item.
---@param pattern string @Lua pattern with one capture for the top of the roll
---@return number|nil, string|nil @Highest roll found, and the affix name it came from
local function findTopAffix(pattern)
	local best, bestAffix
	for _, modEntry in pairs(data.itemMods.Explicit) do
		local rollable = false
		for _, weight in ipairs(modEntry.weightVal or { }) do
			if weight > 0 then
				rollable = true
				break
			end
		end
		if rollable then
			for _, line in ipairs(modEntry) do
				local roll = tonumber(line:match(pattern) or "")
				if roll and (not best or roll > best) then
					best, bestAffix = roll, modEntry.affix
				end
			end
		end
	end
	return best, bestAffix
end

---Lists modifiers whose value is quantised by integer division (a PerStat tag with a
---divisor above 1). These are the mechanical source of stepped scaling: ModStore floors
---the division, so the modifier only pays out when the underlying stat crosses a multiple
---of the divisor. A marginal sample can land either side of a threshold, which is what
---makes a derivative untrustworthy on these axes.
---@param modDB table @Player mod database
---@param output table @Player output, used to locate the next threshold
local function findSteppedMods(modDB, output)
	local found = { }
	for name, modList in pairs(modDB.mods) do
		for _, mod in ipairs(modList) do
			for _, tag in ipairs(mod) do
				if tag.type == "PerStat" and (tag.div or 1) > 1 and type(mod.value) == "number" then
					local stat = tag.stat or (tag.statList and table.concat(tag.statList, "+")) or "?"
					local current = output[stat] or 0
					local steps = m_floor(current / tag.div)
					t_insert(found, {
						name = name,
						value = mod.value,
						div = tag.div,
						stat = stat,
						current = current,
						steps = steps,
						granted = mod.value * steps,
						toNext = (steps + 1) * tag.div - current,
						source = mod.source or "?",
					})
				end
			end
		end
	end
	t_sort(found, function(a, b) return a.granted > b.granted end)
	return found
end

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

	-- A trend is only meaningful when the marginal yield moves consistently in one
	-- direction. Quantised scaling ("+1 Energy Shield per 10 Strength") makes it bounce
	-- instead, and comparing only the endpoints would render that bouncing as a
	-- confident-looking trend. Direction changes alone are not enough to reject a trend,
	-- since the smallest samples carry rounding noise; the spread between the best and
	-- worst yield has to be wide enough to matter as well.
	local rising, falling = false, false
	local lo, hi = first.perUnit, first.perUnit
	for i = 2, #samples do
		local prev, cur = samples[i - 1].perUnit, samples[i].perUnit
		if prev > 0 then
			if cur / prev > 1.02 then
				rising = true
			elseif cur / prev < 0.98 then
				falling = true
			end
		end
		lo, hi = m_min(lo, cur), m_max(hi, cur)
	end
	if rising and falling and lo > 0 and hi / lo > 1.25 then
		return s_format("IRREGULAR (%.2fx)", hi / lo)
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
---@param showSweep boolean|nil @Also dump every sample point behind each classification
function calcs.runSensitivity(build, statName, showSweep)
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

			-- Measured rather than extrapolated from the sweep: on a stepped axis a
			-- linear extrapolation from a different step size can be badly off.
			local affixSize, affixName = findTopAffix(axis.affixPattern)
			local affixGain, affixPct
			if affixSize then
				local output = calcFunc({ extraMods = { modLib.createMod(axis.mod, "BASE", affixSize, "Sensitivity") } })
				affixGain = (output[statName] or 0) - baseValue
				affixPct = affixGain / baseValue * 100
			end

			local entry = {
				label = axis.label,
				current = current,
				step = step,
				delta = nominal.delta,
				elasticity = elasticity,
				curve = classifyCurve(samples),
				samples = samples,
				affixSize = affixSize,
				affixName = affixName,
				affixGain = affixGain,
				affixPct = affixPct,
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

	-- Ordered by per-affix gain, which is the actionable question ("what should I put in
	-- the next slot"). Elasticity is kept as a column because it answers the structural
	-- question instead, and the two orderings genuinely disagree: a stat with a small
	-- pool is cheap to move by 1% but still capped by what one affix can grant.
	t_sort(poolResults, function(a, b) return (a.affixGain or -1) > (b.affixGain or -1) end)
	t_sort(multResults, function(a, b) return a.pct > b.pct end)

	out("")
	out("--- EIXOS DE POOL (ordenado por ganho de um afixo real) ---")
	out("%-16s %9s %8s %13s %7s %8s  %s", "Eixo", "Atual", "Afixo", "Ganho/afixo", "%", "Elast.", "Curva")
	for _, r in ipairs(poolResults) do
		if r.affixSize then
			out("%-16s %9.0f %8d %13.1f %6.2f%% %8.3f  %s", r.label, r.current, r.affixSize, r.affixGain, r.affixPct, r.elasticity, r.curve)
		else
			out("%-16s %9.0f %8s %13s %7s %8.3f  %s", r.label, r.current, "n/d", "n/d", "n/d", r.elasticity, r.curve)
		end
	end
	out("")
	out("Afixo = maior roll plano do pool explicito do jogo. Fontes:")
	for _, r in ipairs(poolResults) do
		if r.affixName then
			out("  %-16s +%d (%s)", r.label, r.affixSize, r.affixName)
		end
	end

	out("")
	out("--- EIXOS MULTIPLICADORES (ganho por afixo tipico) ---")
	out("%-28s %8s %14s %8s  %s", "Eixo", "Passo", "Ganho", "%", "Curva")
	for _, r in ipairs(multResults) do
		out("%-28s %7d%s %14.1f %7.2f%%  %s", r.label, r.step, r.unit, r.delta, r.pct, r.curve)
	end

	-- Stepped scaling sources present in this build. Printed unconditionally because they
	-- are what makes the curve column unreliable, and because the distance to the next
	-- threshold is directly actionable.
	local mainEnv = build.calcsTab and build.calcsTab.mainEnv
	local modDB = mainEnv and mainEnv.player and mainEnv.player.modDB
	if modDB then
		local stepped = findSteppedMods(modDB, baseOutput)
		out("")
		out("--- FONTES DE ESCALONAMENTO EM DEGRAU (PerStat com divisao inteira) ---")
		if #stepped == 0 then
			out("Nenhuma encontrada.")
		else
			out("%-18s %7s %-18s %9s %7s %9s %9s", "Concede", "Por", "A cada N de", "Atual", "Degraus", "Total", "Falta")
			for _, m in ipairs(stepped) do
				out("%-18s %7.1f %-18s %9.0f %7d %9.1f %9.1f", m.name, m.value, m.div .. " " .. m.stat, m.current, m.steps, m.granted, m.toNext)
			end
			out("")
			out("'Falta' = quanto do stat falta para o proximo degrau.")
		end
	else
		out("")
		out("(nao foi possivel inspecionar o modDB para fontes em degrau)")
	end

	-- Raw sample points behind every classification. The summary tables report a single
	-- derivative, which is only trustworthy when the axis pays out continuously; this
	-- section is what lets a stepped or non-linear axis be recognised as such instead of
	-- being read as a smooth number. Off by default because it is only worth reading
	-- when a classification looks suspect.
	if showSweep then
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
	else
		out("")
		out("(Shift+F7 para o detalhe do sweep de cada eixo)")
	end

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
