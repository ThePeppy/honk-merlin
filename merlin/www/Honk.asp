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
<title>Honk 代理</title>
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

var honkRuntime = {
	off: "已关闭",
	on: "运行中",
	armed: "运行中",
	confirmed: "运行中",
	refused: "未能启动"
};

var honkDetail = {
	boot_off: "开机默认关闭，请手动启动",
	running: "运行中",
	armed: "运行中",
	confirmed: "运行中",
	off: "已关闭",
	stopped: "已关闭",
	restart: "正在重启",
	uninstalled: "已卸载",
	not_armed: "尚未启动",
	listener_down: "进程已退出，已关闭拦截",
	confirm_timeout: "已关闭",
	ping_failed: "网关不通，已关闭拦截",
	apply_failed: "规则未能生效，已关闭拦截",
	need_conntrack: "conntrack 不可用，未能启动",
	need_model: "仅支持 RT-BE88U",
	need_sw_mode: "需要路由模式",
	need_gateway: "未找到 WAN 网关",
	need_primary: "局域网主地址与 lan_ipaddr 不一致",
	need_facts: "重定向计划被拒绝",
	need_curl: "未找到 curl",
	need_subscription: "订阅相关请在 doona 面板处理",
	need_config: "缺少 /jffs/addons/honk/config.dae，未能启动"
};

function honkLabel(table, value) {
	var known = table[value];
	if (known) {
		return known;
	}
	return value;
}

function honkNote(runtime, detail) {
	if (runtime !== "refused") {
		return "";
	}
	return honkLabel(honkDetail, detail);
}

function initial() {
	show_menu();
	var page = window.location.pathname.split("/").pop();
	document.form.current_page.value = page;
	document.form.next_page.value = page;
	var db = custom_settings || {};
	var runtime = honkSafe(db.honk_runtime) || "off";
	var detail = honkSafe(db.honk_detail) || "boot_off";
	honkText("honk_runtime", honkLabel(honkRuntime, runtime));
	honkText("honk_detail", honkLabel(honkDetail, detail));
	honkText("honk_note", honkNote(runtime, detail));
}

function submitHonk(action) {
	document.form.amng_custom.value = "";
	document.form.action_script.value = action;
	document.form.action_wait.value = "8";
	showLoading();
	document.form.submit();
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
										<div class="formfonttitle">Honk 代理</div>
										<div style="margin:10px 0 10px 5px;" class="splitLine"></div>
										<div class="formfontdesc">本页只负责启动、重启与关闭 Honk。订阅、节点、分组、规则与配置请在 doona 面板中管理。</div>
										<div class="formfontdesc">开机不会自动启动。关闭可立即停止拦截并恢复加速。</div>
										<div id="honk_note" class="formfontdesc"></div>

										<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
											<thead>
												<tr>
													<td colspan="2">状态</td>
												</tr>
											</thead>
											<tr>
												<th width="40%">运行</th>
												<td id="honk_runtime">已关闭</td>
											</tr>
											<tr>
												<th>详情</th>
												<td id="honk_detail">开机默认关闭，请手动启动</td>
											</tr>
											<tr>
												<th>监听</th>
												<td>局域网地址，TCP 端口与 tproxy_port 相同（未写时为 12345）。UDP 不经过 Honk。</td>
											</tr>
											<tr>
												<th>面板</th>
												<td><a href="http://192.168.2.1:9090/ui/" target="_blank">打开 doona（9090）</a></td>
											</tr>
											<tr>
												<th>配置文件</th>
												<td>/jffs/addons/honk/config.dae（含 include nodes.dae）</td>
											</tr>
										</table>

										<div class="apply_gen">
											<input type="button" class="button_gen" onclick="submitHonk('start_honk');" value="启动"/>
											<input type="button" class="button_gen" onclick="submitHonk('restart_honk');" value="重启"/>
											<input type="button" class="button_gen" onclick="submitHonk('stop_honk');" value="关闭"/>
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
