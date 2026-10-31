<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<html xmlns:v>
<!-- honk-addon-page -->
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<meta HTTP-EQUIV="Pragma" CONTENT="no-cache">
<meta HTTP-EQUIV="Expires" CONTENT="-1">
<link rel="shortcut icon" href="images/favicon.png">
<link rel="icon" href="images/favicon.png">
<title><#Web_Title#> - Honk</title>
<link rel="stylesheet" type="text/css" href="index_style.css">
<link rel="stylesheet" type="text/css" href="form_style.css">
<link rel="stylesheet" type="text/css" href="css/icon.css">
<script type="text/javascript" src="/js/jquery.js"></script>
<script language="JavaScript" type="text/javascript" src="/state.js"></script>
<script language="JavaScript" type="text/javascript" src="/general.js"></script>
<script language="JavaScript" type="text/javascript" src="/popup.js"></script>
<script language="JavaScript" type="text/javascript" src="/help.js"></script>
<script type="text/javascript" src="/js/httpApi.js"></script>
<script language="JavaScript" type="text/javascript" src="/validator.js"></script>
<script type="text/javascript" src="/form.js"></script>
<script>
var custom_settings = <% get_custom_settings(); %>;

function honkSafe(value) {
	if (typeof value !== "string") {
		return "";
	}
	if (!/^[A-Za-z0-9_.:-]*$/.test(value)) {
		return "";
	}
	return value;
}

function honkText(id, value) {
	var node = document.getElementById(id);
	while (node.firstChild) {
		node.removeChild(node.firstChild);
	}
	node.appendChild(document.createTextNode(value));
}

var honkRefusal = {
	need_conntrack: "Conntrack is not usable, so interception was not enabled. conntrack 不可用，因此没有开始拦截。",
	need_model: "This addon only runs on an RT-BE88U. 仅支持 RT-BE88U。",
	need_sw_mode: "Router mode is required. 需要路由模式 (sw_mode 1)。",
	need_gateway: "No WAN gateway was found. 没有找到 WAN 网关。",
	need_primary: "The LAN primary address does not match lan_ipaddr. 局域网主地址与 lan_ipaddr 不一致。",
	need_facts: "The redirect plan was refused. 重定向计划被拒绝。",
	need_curl: "curl was not found, so the subscription was not refreshed. 没有找到 curl，订阅没有刷新。",
	need_subscription: "The subscription could not be fetched, so interception was not enabled. 订阅下载失败，因此没有开始拦截。",
	need_config: "The config did not load, so interception was not enabled. 配置没有载入，因此没有开始拦截。"
};

function honkNote(runtime, detail) {
	if (runtime !== "refused") {
		return "";
	}
	if (honkRefusal[detail]) {
		return honkRefusal[detail];
	}
	return detail;
}

function initial() {
	show_menu();
	var page = window.location.pathname.split("/").pop();
	document.form.current_page.value = page;
	document.form.next_page.value = page;
	var db = custom_settings || {};
	var runtime = honkSafe(db.honk_runtime) || "off";
	var detail = honkSafe(db.honk_detail) || "boot_off";
	var minutes = honkSafe(db.honk_confirm_minutes) || "5";
	honkText("honk_runtime", runtime);
	honkText("honk_detail", detail);
	honkText("honk_note", honkNote(runtime, detail));
	var select = document.getElementById("honk_confirm_minutes");
	if (select && /^(1|2|5|10|15|30)$/.test(minutes)) {
		select.value = minutes;
	}
}

function submitHonk(action) {
	var minutes = document.getElementById("honk_confirm_minutes").value;
	if (!/^(1|2|5|10|15|30)$/.test(minutes)) {
		minutes = "5";
	}
	var fields = ["honk_confirm_minutes=" + minutes];
	var nodes = document.getElementsByTagName("select");
	var i;
	for (i = 0; i < nodes.length; i++) {
		if (nodes[i].id.indexOf("honk_sel_") === 0) {
			fields.push(nodes[i].id + "=" + nodes[i].value);
		}
	}
	document.form.amng_custom.value = fields.join(";");
	document.form.action_script.value = action;
	document.form.action_wait.value = "8";
	showLoading();
	document.form.submit();
	// start_apply can hide the spinner without painting this page again.
	// Reload after the service-event child has stored honk_runtime.
	setTimeout(function() {
		window.location.reload();
	}, 8000);
}
</script>
</head>

<body onload="initial();" onunLoad="return unload_body();" class="bg">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>

<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value="">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply">
<input type="hidden" name="action_wait" value="8">
<input type="hidden" name="action_script" value="">
<input type="hidden" name="amng_custom" id="amng_custom" value="">

<table class="content" align="center" cellpadding="0" cellspacing="0">
	<tr>
		<td width="17">&nbsp;</td>
		<td valign="top" width="202">
			<div id="mainMenu"></div>
			<div id="subMenu"></div>
		</td>
		<td valign="top">
			<div id="tabMenu" class="submenuBlock"></div>
			<table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
				<tr>
					<td valign="top">
						<table width="760px" border="0" cellpadding="4" cellspacing="0" class="FormTitle" id="FormTitle">
							<tbody>
							<tr>
								<td bgcolor="#4D595D" valign="top">
									<div class="container">
										<div>&nbsp;</div>
										<div class="formfonttitle"><#menu5_6#> - Honk</div>
										<div style="margin:10px 0 10px 5px;" class="splitLine"></div>
										<div class="formfontdesc">Phase 1 listens on the LAN address and copies TCP to the original destination. It does not dial a proxy node. Interception stays off after every boot until Enable is pressed on this page. Keep an SSH session open. If LAN web access fails, wait for the confirm timer or run the uninstall script.</div>
										<div class="formfontdesc">第一阶段只把局域网 IPv4 TCP 转到原始目的地址，不使用代理节点。每次开机都不会拦截，必须在本页点击 Enable。请保持一个 SSH 会话。如果网页打不开，等待确认倒计时结束，或执行卸载脚本。</div>
										<div id="honk_note" class="formfontdesc" style="color:#FC0;"></div>
										<div class="formfontdesc">honk-core can serve a Clash dashboard when experimental.clash_api.external_controller is set. This addon runs honk-dataplane only, so nothing listens on port 9090. honk-core 的 Clash 面板属于 honk-core 进程；本插件只运行 honk-dataplane，不会打开 9090。</div>

										<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
											<thead>
												<tr>
													<td colspan="2">Honk</td>
												</tr>
											</thead>
											<tr>
												<th width="40%">Runtime</th>
												<td id="honk_runtime">off</td>
											</tr>
											<tr>
												<th>Detail</th>
												<td id="honk_detail">boot_off</td>
											</tr>
											<tr>
												<th>Listen</th>
												<td>LAN primary address, TCP 39527</td>
											</tr>
											<!-- honk-groups-begin -->
											<tr>
												<th>Groups</th>
												<td>Copy config.dae into the addon directory, then press Refresh.</td>
											</tr>
											<!-- honk-groups-end -->
											<tr>
												<th>Config</th>
												<td>/jffs/addons/honk/config.dae</td>
											</tr>
											<tr>
												<th>Confirm within minutes</th>
												<td>
													<select id="honk_confirm_minutes" class="input_option">
														<option value="1">1</option>
														<option value="2">2</option>
														<option value="5" selected>5</option>
														<option value="10">10</option>
														<option value="15">15</option>
														<option value="30">30</option>
													</select>
												</td>
											</tr>
										</table>

										<div class="apply_gen">
											<input type="button" class="button_gen" onclick="submitHonk('start_honk');" value="Enable"/>
											<input type="button" class="button_gen" onclick="submitHonk('start_honkconfirm');" value="Confirm"/>
											<input type="button" class="button_gen" onclick="submitHonk('stop_honk');" value="Disable"/>
											<input type="button" class="button_gen" onclick="submitHonk('start_honkrefresh');" value="Refresh"/>
										</div>
									</div>
								</td>
							</tr>
							</tbody>
						</table>
					</td>
				</tr>
			</table>
		</td>
		<td width="10" align="center" valign="top"></td>
	</tr>
</table>
</form>
<div id="footer"></div>
</body>
</html>
