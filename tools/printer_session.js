// Generated from FP-RISC printer-dashboard/sessionprogram.
((function(){let checking=false;
async function check(){if((checking||(document)["hidden"])){return;
}else{}
(checking=true);
try{const response=(await (fetch)("/auth/session",({["credentials"]:"same-origin",["cache"]:"no-store"})));
if(((response)["status"]===401)){((location)["replace"])("/");
}else{}
}catch(_){}finally{(checking=false);
}
}
((document)["addEventListener"])("click",(async function(event){if((!(((event)["target"])["closest"])("[data-sign-out]"))){return;
}else{}
((event)["preventDefault"])();
try{const response=(await (fetch)("/auth/logout",({["method"]:"POST",["headers"]:({["Content-Type"]:"application/json"}),["body"]:"{}",["credentials"]:"same-origin"})));
if((response)["ok"]){((location)["replace"])("/");
}else{}
}catch(_){(alert)("Could not sign out. Please retry when connected.");
}finally{}
}));
(setInterval)(check,15000);
((document)["addEventListener"])("visibilitychange",check);
(check)();
}))();
