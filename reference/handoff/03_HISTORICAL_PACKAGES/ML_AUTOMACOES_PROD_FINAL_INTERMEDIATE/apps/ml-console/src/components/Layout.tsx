import { NavLink,Outlet } from "react-router-dom";
const links=[["/","Dashboard"],["/agenda","Agenda"],["/clientes","Clientes"],["/servicos","Serviços"],["/equipe","Equipe"],["/produtos","Produtos"],["/campanhas","Campanhas"],["/knowledge","Knowledge"],["/automacoes","Automações"],["/incidentes","Incidentes"],["/config","Configurações"]];
export function Layout(){return <div className="shell"><aside><h2>ML Automações</h2>{links.map(([to,l])=><NavLink key={to} to={to}>{l}</NavLink>)}</aside><main><Outlet/></main></div>}
